//
//  AboutTab.swift
//  Paprika
//

import AppKit
import PaprikaKit
import SwiftUI

struct AboutTab: View {
    @EnvironmentObject private var model: AppModel

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? PaprikaVersion.current
    }

    var body: some View {
        SettingsForm {
            HStack(alignment: .top, spacing: 16) {
                PepperGaugeView(
                    fraction: 0.8,
                    state: .holding,
                    limitFraction: 0.8,
                    size: 72,
                    showOverlaySymbol: false
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text("Paprika")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text(L.s("맥북 배터리 충전 상한 지킴이", "MacBook charge limiter"))
                        .foregroundStyle(.secondary)
                    Text("v\(appVersion) · helper \(model.snapshot?.helperVersion ?? "–")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }

            SettingsSection {
                Text(L.s(
                    """
                    리튬이온 배터리는 100% 로 오래 방치할 때 가장 빨리 늙습니다. \
                    책상에 꽂아두고 쓰는 시간이 많다면 상한을 80% 정도로 잡아두는 게 \
                    수명에 가장 도움이 됩니다.

                    외출 직전에는 '이번 한 번만 100% 까지 충전'을 눌러 두면 \
                    100% 를 채운 뒤 자동으로 원래 상한으로 돌아갑니다.
                    """,
                    """
                    Lithium-ion cells age fastest when they sit at 100%. \
                    If your Mac lives on a desk, an 80% ceiling is the single \
                    most useful thing you can do for its lifespan.

                    Before heading out, use “Charge to 100% just this once” — \
                    it tops up and then returns to your usual limit automatically.
                    """
                ))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L.s("왜 상한을 두나요?", "Why limit charging?"))
            }

            SettingsSection {
                VStack(alignment: .leading, spacing: 8) {
                    BulletRow(L.s(
                        "이 앱은 SMC(시스템 관리 컨트롤러)에 직접 값을 씁니다. 문서화되지 않은 영역이라 기기·펌웨어에 따라 동작이 다를 수 있습니다.",
                        "This app writes directly to the SMC. That area is undocumented, so behaviour varies by model and firmware."
                    ))
                    BulletRow(L.s(
                        "충전을 막아 둔 상태에서 도우미가 강제 종료되면 충전이 막힌 채로 남을 수 있습니다. 그래서 정상 종료 시에는 항상 원상복구하고, '고급 → 복구'에서 수동으로도 되돌릴 수 있게 해두었습니다.",
                        "If the helper is killed while charging is inhibited, it can stay inhibited. That's why it always restores on a clean exit, and why Advanced → Recovery exists."
                    ))
                    BulletRow(L.s(
                        "맥을 완전히 껐다 켜면 SMC 값은 대체로 초기화됩니다. 무언가 이상하면 재부팅이 가장 빠른 복구 수단입니다.",
                        "A full shutdown usually clears SMC state. If something looks wrong, rebooting is the quickest fix."
                    ))
                    BulletRow(L.s(
                        "macOS 자체의 '배터리 충전 최적화'와 동시에 쓰면 서로 간섭할 수 있습니다. 한쪽만 쓰는 것을 권합니다.",
                        "Running this alongside macOS's own optimised battery charging can cause the two to fight. Pick one."
                    ))
                }
            } header: {
                Text(L.s("알아두어야 할 점", "Things to know"))
            }

            SettingsSection {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.s(
                        "충전 제어에 쓰이는 SMC 키의 의미는 다음 오픈소스 프로젝트들의 문서에서 확인했습니다. 코드를 가져오지는 않았고, 하드웨어 동작에 관한 사실만 참고했습니다.",
                        "The meaning of the charge-control SMC keys was confirmed from the documentation of these open-source projects. No code was copied — only hardware facts."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    LinkRow(title: "charlie0129/batt", url: "https://github.com/charlie0129/batt")
                    LinkRow(title: "killerk3emstar/OpenDente", url: "https://github.com/killerk3emstar/OpenDente")
                    LinkRow(title: "zackelia/bclm", url: "https://github.com/zackelia/bclm")
                    LinkRow(
                        title: L.s("Apple — 배터리 건강 관리", "Apple — battery health management"),
                        url: "https://support.apple.com/en-us/102589"
                    )
                }
            } header: {
                Text(L.s("참고 자료", "References"))
            }

            if let system = model.snapshot?.capabilities.system {
                SettingsSection {
                    InfoLine(L.s("모델", "Model"), system.modelIdentifier)
                    InfoLine(L.s("칩", "Chip"), system.chipName)
                    InfoLine("macOS", system.osVersion)
                    InfoLine(
                        L.s("Apple Silicon", "Apple Silicon"),
                        system.isAppleSilicon ? L.s("예", "yes") : L.s("아니오", "no")
                    )
                } header: {
                    Text(L.s("이 맥", "This Mac"))
                }
            }
        }
    }
}

private struct BulletRow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct LinkRow: View {
    let title: String
    let url: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let destination = URL(string: url) {
                Link(title, destination: destination)
                    .font(.caption)
            } else {
                Text(title).font(.caption)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct InfoLine: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}
