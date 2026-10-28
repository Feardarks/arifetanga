#include "SMBShim.h"
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <smb2/libsmb2-dcerpc-srvsvc.h>
#include <smb2/libsmb2-raw.h>

struct arif_share_result {
    int finished;
    int status;
    char *names;
};

static void arif_share_cb(struct smb2_context *smb2, int status, void *command_data, void *private_data) {
    struct arif_share_result *result = private_data;
    result->finished = 1;
    result->status = status;
    if (status != 0) {
        return;
    }
    struct srvsvc_NetrShareEnum_rep *rep = command_data;
    size_t length = 1;
    uint32_t count = rep->ses.ShareInfo.Level1.EntriesRead;
    struct srvsvc_SHARE_INFO_1 *infos = rep->ses.ShareInfo.Level1.Buffer->share_info_1;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = infos[i].netname.utf8;
        if (name) {
            length += strlen(name) + 1;
        }
    }
    char *out = calloc(length, 1);
    if (out) {
        for (uint32_t i = 0; i < count; i++) {
            const char *name = infos[i].netname.utf8;
            size_t n = name ? strlen(name) : 0;
            // Yalnızca disk paylaşımları; ADMIN$, C$ gibi gizli olanlar atlanır.
            if (n == 0 || (infos[i].type & 3) != SHARE_TYPE_DISKTREE || (infos[i].type & SHARE_TYPE_HIDDEN) ||
                name[n - 1] == '$') {
                continue;
            }
            strcat(out, name);
            strcat(out, "\n");
        }
    } else {
        result->status = -ENOMEM;
    }
    result->names = out;
    smb2_free_data(smb2, rep);
}

int arif_smb2_share_enum(struct smb2_context *smb2, int timeout_ms, char **names) {
    struct arif_share_result result = {0, 0, NULL};
    *names = NULL;
    int rc = smb2_share_enum_async(smb2, SHARE_INFO_1, arif_share_cb, &result);
    if (rc != 0) {
        return rc;
    }
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (!result.finished) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed = (now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) / 1000000;
        if (elapsed > timeout_ms) {
            return -ETIMEDOUT;
        }
        struct pollfd pfd = { .fd = smb2_get_fd(smb2), .events = (short)smb2_which_events(smb2), .revents = 0 };
        if (poll(&pfd, 1, 200) < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -errno;
        }
        if (smb2_service(smb2, pfd.revents) < 0) {
            return -EIO;
        }
    }
    if (result.status != 0) {
        free(result.names);
        return result.status;
    }
    *names = result.names;
    return 0;
}

// MARK: Ardışık düzenli okuma

struct arif_batch;

struct arif_piece {
    struct arif_batch *batch;
    uint32_t requested;
    int64_t result;
    int done;
};

/// Okuma grubunun durumu yığında tutulur: çağıran vazgeçip döndükten sonra da yarıda kalan isteklerin geri
/// çağrıları (bağlam yok edilirken) buraya yazar. Son başvuru bırakınca serbest kalır.
struct arif_batch {
    int refs;
    int completed;
    struct arif_piece pieces[];
};

static void arif_batch_release(struct arif_batch *batch) {
    if (--batch->refs == 0) {
        free(batch);
    }
}

static void arif_read_cb(struct smb2_context *smb2, int status, void *command_data, void *private_data) {
    struct arif_piece *piece = private_data;
    struct arif_batch *batch = piece->batch;
    piece->result = status;
    piece->done = 1;
    batch->completed++;
    arif_batch_release(batch);
}

static long arif_ms_since(const struct timespec *start) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (now.tv_sec - start->tv_sec) * 1000 + (now.tv_nsec - start->tv_nsec) / 1000000;
}

int64_t arif_smb2_pread_pipelined(struct smb2_context *smb2, struct smb2fh *fh, uint8_t *buf, uint64_t count,
                                  uint64_t offset, uint32_t piece, int depth, int timeout_ms) {
    if (count == 0) {
        return 0;
    }
    uint32_t max_read = smb2_get_max_read_size(smb2);
    if (max_read == 0) {
        max_read = 65536;
    }
    if (piece == 0 || piece > max_read) {
        piece = max_read;
    }
    if (depth < 1) {
        depth = 1;
    }
    uint64_t pieces = (count + piece - 1) / piece;
    struct arif_batch *batch = calloc(1, sizeof(struct arif_batch) + pieces * sizeof(struct arif_piece));
    if (batch == NULL) {
        return -ENOMEM;
    }
    batch->refs = 1;
    for (uint64_t i = 0; i < pieces; i++) {
        batch->pieces[i].batch = batch;
        uint64_t remaining = count - i * piece;
        batch->pieces[i].requested = (uint32_t)(remaining < piece ? remaining : piece);
    }

    int64_t error = 0;
    uint64_t issued = 0;
    int last_completed = 0;
    struct timespec progress;
    clock_gettime(CLOCK_MONOTONIC, &progress);
    while (batch->completed < (int)pieces) {
        // Pencere: en çok `depth` istek uçuşta.
        while (issued < pieces && (int64_t)issued - batch->completed < depth) {
            struct arif_piece *p = &batch->pieces[issued];
            batch->refs++;
            int rc = smb2_pread_async(smb2, fh, buf + issued * piece, p->requested, offset + issued * piece,
                                      arif_read_cb, p);
            if (rc < 0) {
                batch->refs--;
                error = rc;
                break;
            }
            issued++;
        }
        if (error) {
            break;
        }
        for (uint64_t i = 0; i < issued; i++) {
            if (batch->pieces[i].done && batch->pieces[i].result < 0) {
                error = batch->pieces[i].result;
                break;
            }
        }
        if (error || batch->completed == (int)pieces) {
            break;
        }
        if (batch->completed != last_completed) {
            last_completed = batch->completed;
            clock_gettime(CLOCK_MONOTONIC, &progress);
        } else if (arif_ms_since(&progress) > timeout_ms) {
            error = -ETIMEDOUT;
            break;
        }
        struct pollfd pfd = { .fd = smb2_get_fd(smb2), .events = (short)smb2_which_events(smb2), .revents = 0 };
        int ready = poll(&pfd, 1, 100);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            error = -errno;
            break;
        }
        if (ready == 0) {
            continue;
        }
        if (smb2_service(smb2, pfd.revents) < 0) {
            error = -EIO;
            break;
        }
    }

    int64_t total = 0;
    if (!error) {
        for (uint64_t i = 0; i < pieces; i++) {
            if (batch->pieces[i].result < 0) {
                error = batch->pieces[i].result;
                break;
            }
            total += batch->pieces[i].result;
            if ((uint64_t)batch->pieces[i].result < batch->pieces[i].requested) {
                break;
            }
        }
    }
    arif_batch_release(batch);
    return error ? error : total;
}
