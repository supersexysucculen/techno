//
//  PeerValidator.swift
//  paprikad
//
//  root 권한으로 SMC 를 쓰는 데몬이므로, 아무 프로세스나 붙어서 명령을 던지게
//  두면 안 된다. 연결을 요청한 프로세스의 코드서명을 확인한다.
//
//  한계(정직하게 적어둠)
//  --------------------
//  * PID 기반 확인은 원리상 경합(PID 재사용)에 취약하다. 정식 배포 앱이라면
//    audit token 기반 확인이 맞지만 그 API 는 공개돼 있지 않다.
//    혼자 쓰는 앱에서는 이 정도가 합리적인 타협점이다.
//  * ad-hoc 서명(무료 빌드)에서는 팀 ID 로 묶을 수 없어 "identifier" 만 본다.
//    솔직히 말하면, 이 경우 검증이 증명하는 것은 "호출자가 스스로 서명했다"는 것뿐이다.
//    identifier 는 비밀이 아니고(build.sh 에 그대로 적혀 있다) ad-hoc 서명은 인증서가
//    필요 없으므로 누구나 같은 identifier 로 서명할 수 있다.
//    제대로 막으려면 개발자 인증서로 서명하고 요구사항에
//      anchor apple generic and certificate leaf[subject.OU] = "TEAMID"
//    를 추가해야 한다. 실질적인 방어선은 오히려 데몬 바이너리를 관리자도 못 고치는
//    /Library/PrivilegedHelperTools 에 두는 것이다.
//  * /Library/Application Support/Paprika/allow-unsigned-peers 파일을 만들어 두면
//    검사를 아예 건너뛴다. 직접 빌드해서 디버깅할 때만 쓰자.
//

import Foundation
import PaprikaKit
import Security

struct PeerVerdict {
    var allowed: Bool
    var detail: String
}

enum PeerValidator {

    /// 허용할 코드서명 identifier 들.
    /// ad-hoc 서명이면 보통 번들 ID(앱) 또는 실행 파일 이름(CLI)이 identifier 가 된다.
    private static let allowedIdentifiers = [
        PaprikaPaths.appBundleIdentifier,
        "Paprika",
        "paprikactl",
        "com.paprika.paprikactl",
    ]

    private static var requirementString: String {
        allowedIdentifiers
            .map { "identifier \"\($0)\"" }
            .joined(separator: " or ")
    }

    static func evaluate(connection: NSXPCConnection) -> PeerVerdict {
        let pid = connection.processIdentifier

        if FileManager.default.fileExists(atPath: PaprikaPaths.allowUnsignedPeersFile) {
            return PeerVerdict(
                allowed: true,
                detail: "pid \(pid): allow-unsigned-peers 파일이 있어 서명 검사를 건너뜁니다."
            )
        }

        guard let code = copyCode(for: pid) else {
            return PeerVerdict(allowed: false, detail: "pid \(pid): SecCode 를 가져올 수 없습니다.")
        }

        let identifier = signingIdentifier(of: code) ?? "<unknown>"

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else {
            return PeerVerdict(allowed: false, detail: "pid \(pid): 요구사항 문자열을 만들지 못했습니다.")
        }

        let status = SecCodeCheckValidity(code, [], requirement)
        guard status == errSecSuccess else {
            return PeerVerdict(
                allowed: false,
                detail: "pid \(pid) identifier=\(identifier): 서명 검사 실패 (OSStatus \(status)). "
                    + "직접 빌드한 앱이라면 \(PaprikaPaths.allowUnsignedPeersFile) 를 만들어 주세요."
            )
        }

        return PeerVerdict(allowed: true, detail: "pid \(pid) identifier=\(identifier)")
    }

    private static func copyCode(for pid: pid_t) -> SecCode? {
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else {
            return nil
        }
        return code
    }

    private static func signingIdentifier(of code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [AnyHashable: Any]
        else { return nil }

        return dictionary[kSecCodeInfoIdentifier as String] as? String
    }
}
