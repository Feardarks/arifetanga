import Foundation
import XCTest
@testable import MediaIO

final class SMBLocationTests: XCTestCase {
    func testURLRoundTripKeepsTurkishNamesSpacesAndDisplayName() throws {
        let location = SMBLocation(server: SMBServer(host: "192.168.1.10", user: "ali", name: "DiskStation"),
                                   share: "Filmler", path: "Alt Klasör/Şahane Film (2024).mkv")
        let url = try XCTUnwrap(location.url)
        XCTAssertEqual(url.scheme, "smb")
        XCTAssertEqual(url.lastPathComponent, "Şahane Film (2024).mkv")
        XCTAssertEqual(url.pathExtension, "mkv")
        XCTAssertFalse(url.absoluteString.contains("parola"))
        XCTAssertEqual(SMBLocation(url: url), location)
        XCTAssertEqual(location.displayPath, "DiskStation/Filmler/Alt Klasör/Şahane Film (2024).mkv")
        XCTAssertEqual(location.fileName, "Şahane Film (2024).mkv")
    }

    func testPortDomainAndGuest() throws {
        let withDomain = SMBLocation(server: SMBServer(host: "nas.local:4445", user: "test", domain: "WORKGROUP"),
                                     share: "FILMLER", path: "a/b.m2ts")
        let url = try XCTUnwrap(withDomain.url)
        XCTAssertEqual(url.port, 4445)
        XCTAssertEqual(url.host, "nas.local")
        XCTAssertEqual(SMBLocation(url: url), withDomain)

        let guest = SMBLocation(server: SMBServer(host: "nas"), share: "Ortak", path: "")
        let guestURL = try XCTUnwrap(guest.url)
        XCTAssertNil(guestURL.user)
        XCTAssertEqual(SMBLocation(url: guestURL), guest)
        XCTAssertEqual(guest.fileName, "Ortak", "paylaşım kökü")
        XCTAssertEqual(guest.server.displayName, "nas")
    }

    func testRejectsNonSMBAndShareless() {
        XCTAssertNil(SMBLocation(url: URL(string: "smb://nas")!))
        XCTAssertNil(SMBLocation(url: URL(fileURLWithPath: "/tmp/film.mkv")))
        XCTAssertEqual(SMBEntry.join("", "Filmler"), "Filmler")
        XCTAssertEqual(SMBEntry.join("Filmler", "film.mkv"), "Filmler/film.mkv")
    }
}
