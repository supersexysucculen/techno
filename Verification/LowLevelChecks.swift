//
//  LowLevelChecks.swift
//  Verification
//
//  커널 ABI 레이아웃, SMC 값 디코딩, FourCharCode, 배터리 속성 해석.
//
//  이 부분은 전부 실제 앱에 들어가는 코드다(대체 구현 없음).
//

import Foundation

func runLowLevelChecks(_ v: Verifier) -> Int {
    var sweptCases = 0

    // ------------------------------------------------------------------ ABI
    v.section("커널 ABI 레이아웃 (SMCParamStruct)")

    v.equal("SMCVersion size", MemoryLayout<SMCVersion>.size, 6)
    v.equal("SMCPLimitData size", MemoryLayout<SMCPLimitData>.size, 16)
    v.equal("SMCKeyInfoData size", MemoryLayout<SMCKeyInfoData>.size, 12)
    v.equal("SMCKeyInfoData stride", MemoryLayout<SMCKeyInfoData>.stride, 12)
    v.equal("SMCParamStruct size", MemoryLayout<SMCParamStruct>.size, 80)
    v.equal("SMCParamStruct stride", MemoryLayout<SMCParamStruct>.stride, 80)
    v.equal("SMCBytes size", MemoryLayout<SMCBytes>.size, 32)
    v.expect("byteLayoutIsValid", SMCParamStruct.byteLayoutIsValid)

    // 실제 메모리에서 필드 오프셋을 측정한다.
    var probe = SMCParamStruct()
    probe.key = 0xA1A1A1A1
    probe.keyInfo.dataSize = 0xB2B2B2B2
    probe.result = 0xC3
    probe.status = 0xD4
    probe.data8 = 0xE5
    probe.data32 = 0xF6F6F6F6
    withUnsafeBytes(of: probe) { raw in
        func offset(of marker: UInt8) -> Int { raw.firstIndex(of: marker) ?? -1 }
        v.equal("key 오프셋", offset(of: 0xA1), 0)
        v.equal("keyInfo.dataSize 오프셋", offset(of: 0xB2), 28)
        v.equal("result 오프셋", offset(of: 0xC3), 40)
        v.equal("status 오프셋", offset(of: 0xD4), 41)
        v.equal("data8 오프셋", offset(of: 0xE5), 42)
        v.equal("data32 오프셋", offset(of: 0xF6), 44)
    }

    // bytes 필드가 48 에서 시작하는지 (마지막 바이트를 표시해서 확인)
    var probe2 = SMCParamStruct()
    withUnsafeMutableBytes(of: &probe2.bytes) { $0[0] = 0x5A }
    _ = withUnsafeBytes(of: probe2) { raw in
        v.equal("bytes 오프셋", raw.firstIndex(of: 0x5A) ?? -1, 48)
    }
    v.equal("selector: readKey", SMCSelector.readKey.rawValue, 5)
    v.equal("selector: writeKey", SMCSelector.writeKey.rawValue, 6)
    v.equal("selector: keyFromIndex", SMCSelector.keyFromIndex.rawValue, 8)
    v.equal("selector: keyInfo", SMCSelector.keyInfo.rawValue, 9)
    v.equal("kKernelIndexSMC", kKernelIndexSMC, 2)
    v.equal("result: success", SMCResult.success, 0)
    v.equal("result: keyNotFound", SMCResult.keyNotFound, 132)
    v.equal("smcMaxDataSize", smcMaxDataSize, 32)

    // --------------------------------------------------------- FourCharCode
    v.section("FourCharCode 변환")

    v.equal("CH0B", String(format: "%08x", smcFourCharCode("CH0B")), "43483042")
    v.equal("CH0C", String(format: "%08x", smcFourCharCode("CH0C")), "43483043")
    v.equal("CHTE", String(format: "%08x", smcFourCharCode("CHTE")), "43485445")
    v.equal("bfF0", String(format: "%08x", smcFourCharCode("bfF0")), "62664630")
    v.equal("bfD0", String(format: "%08x", smcFourCharCode("bfD0")), "62664430")
    v.equal("bfE0", String(format: "%08x", smcFourCharCode("bfE0")), "62664530")
    v.equal("CH0I", String(format: "%08x", smcFourCharCode("CH0I")), "43483049")
    v.equal("CHIE", String(format: "%08x", smcFourCharCode("CHIE")), "43484945")
    v.equal("AC-W", String(format: "%08x", smcFourCharCode("AC-W")), "41432d57")
    v.equal("ACLC", String(format: "%08x", smcFourCharCode("ACLC")), "41434c43")

    // 모든 probe 키가 왕복되어야 한다 — 오타가 있으면 여기서 걸린다.
    var roundTripViolations: [String] = []
    for key in SMCKeys.probeKeys {
        sweptCases += 1
        let roundTripped = smcStringFromCode(smcFourCharCode(key))
        if roundTripped != key {
            roundTripViolations.append("\(key) → \(roundTripped)")
        }
    }
    v.sweep("probe 키 전체 왕복", cases: SMCKeys.probeKeys.count, violations: roundTripViolations)
    v.equal("probe 키 개수", SMCKeys.probeKeys.count, 21)
    v.equal("probe 키 중복 없음", Set(SMCKeys.probeKeys).count, SMCKeys.probeKeys.count)
    v.equal("타입 코드 'flt '", smcStringFromCode(0x666C_7420), "flt ")
    v.equal("타입 코드 'ui32'", smcStringFromCode(0x7569_3332), "ui32")
    v.equal("타입 코드 'sp78'", smcStringFromCode(0x7370_3738), "sp78")
    v.equal("#KEY 왕복", smcStringFromCode(smcFourCharCode("#KEY")), "#KEY")
    v.equal("3글자 키는 왼쪽 정렬", String(format: "%08x", smcFourCharCode("AC-")), "41432d00")

    // ------------------------------------------------------------ SMCValue
    v.section("SMCValue 디코딩 (Apple Silicon 엔디언)")

    v.equal("ui8 0x50", SMCValue(key: "x", type: "ui8 ", bytes: [0x50]).uint8, 80)
    v.equal("ui8 0xFF", SMCValue(key: "x", type: "ui8 ", bytes: [0xFF]).uint8, 255)
    v.equal("si8 -1", SMCValue(key: "x", type: "si8 ", bytes: [0xFF]).int8, -1)
    v.equal("si8 +1 (AC-W 연결)", SMCValue(key: "AC-W", type: "si8 ", bytes: [0x01]).int8, 1)
    v.equal("ui16 LE 0x1234", SMCValue(key: "x", type: "ui16", bytes: [0x34, 0x12]).uint16, 0x1234)
    v.equal("ui32 LE 0x12345678", SMCValue(key: "x", type: "ui32", bytes: [0x78, 0x56, 0x34, 0x12]).uint32, 0x1234_5678)
    v.equal("flag true", SMCValue(key: "x", type: "flag", bytes: [0x01]).flag, true)
    v.equal("flag false", SMCValue(key: "x", type: "flag", bytes: [0x00]).flag, false)
    v.equal("hexString", SMCValue(key: "x", type: "hex_", bytes: [0x01, 0xAB, 0x00]).hexString, "01 ab 00")
    v.isNil("짧은 바이트에서 ui32 는 nil", SMCValue(key: "x", type: "ui32", bytes: [0x01]).uint32)
    v.isNil("빈 바이트에서 uint8 은 nil", SMCValue(key: "x", type: "ui8 ", bytes: []).uint8)

    // 펌웨어 제한 퍼센트는 ui32 리틀엔디언 — 0...100 전부 확인한다.
    var firmwarePercentViolations: [String] = []
    for percent in 0...100 {
        sweptCases += 1
        let value = SMCValue(key: SMCKeys.firmwareLimitUpper, type: "ui32", bytes: [UInt8(percent), 0, 0, 0])
        if value.uint32 != UInt32(percent) {
            firmwarePercentViolations.append("\(percent) → \(String(describing: value.uint32))")
        }
    }
    v.sweep("bfD0 퍼센트 인코딩 0~100", cases: 101, violations: firmwarePercentViolations)

    // sp78 은 예외적으로 빅엔디언
    v.close("sp78 30.5", SMCValue(key: "t", type: "sp78", bytes: [0x1E, 0x80]).sp78 ?? -1, 30.5, tolerance: 0.01)
    v.close("sp78 0", SMCValue(key: "t", type: "sp78", bytes: [0x00, 0x00]).sp78 ?? -1, 0, tolerance: 0.01)
    v.close("sp78 -1", SMCValue(key: "t", type: "sp78", bytes: [0xFF, 0x00]).sp78 ?? 99, -1.0, tolerance: 0.01)

    // flt 은 리틀엔디언 IEEE-754
    v.close("flt 42.5", Double(SMCValue(key: "p", type: "flt ", bytes: [0x00, 0x00, 0x2A, 0x42]).float ?? -1), 42.5, tolerance: 0.001)
    v.close("flt 30.5", Double(SMCValue(key: "t", type: "flt ", bytes: [0x00, 0x00, 0xF4, 0x41]).float ?? -1), 30.5, tolerance: 0.001)
    v.close("flt 0", Double(SMCValue(key: "p", type: "flt ", bytes: [0, 0, 0, 0]).float ?? -1), 0, tolerance: 0.001)

    // numericValue 의 타입 분기
    v.close("numericValue flt", SMCValue(key: "p", type: "flt ", bytes: [0x00, 0x00, 0x2A, 0x42]).numericValue ?? -1, 42.5)
    v.close("numericValue sp78", SMCValue(key: "t", type: "sp78", bytes: [0x1E, 0x80]).numericValue ?? -1, 30.5)
    v.close("numericValue ui8", SMCValue(key: "x", type: "ui8 ", bytes: [77]).numericValue ?? -1, 77)
    v.close("numericValue si8 음수", SMCValue(key: "x", type: "si8 ", bytes: [0xFF]).numericValue ?? 99, -1)
    v.close("numericValue ui32", SMCValue(key: "x", type: "ui32", bytes: [50, 0, 0, 0]).numericValue ?? -1, 50)
    v.close("numericValue hex_ 1바이트", SMCValue(key: "x", type: "hex_", bytes: [2]).numericValue ?? -1, 2)
    v.isNil("알 수 없는 타입 + 여러 바이트 → nil", SMCValue(key: "x", type: "????", bytes: [1, 2, 3]).numericValue)

    // 충전 억제 값의 의미를 직접 확인 (README 의 표와 일치해야 한다)
    v.section("충전 제어 값 의미")
    v.equal("CH0B 허용값", SMCChargeValues.classicAllow, 0x00)
    v.equal("CH0B 차단값", SMCChargeValues.classicInhibit, 0x02)
    v.equal("CHTE 허용값", SMCChargeValues.tahoeAllow, [0x00, 0x00, 0x00, 0x00])
    v.equal("CHTE 차단값", SMCChargeValues.tahoeInhibit, [0x01, 0x00, 0x00, 0x00])
    v.equal("어댑터 사용값", SMCChargeValues.adapterEnable, 0x00)
    v.equal("어댑터 차단값(CH0I/CH0J)", SMCChargeValues.adapterDisable, 0x01)
    v.equal("어댑터 차단값(CHIE)", SMCChargeValues.adapterDisableTahoe, 0x08)
    v.equal("CH0I 차단값 매핑", AdapterControlKey.ch0i.disableValue, 0x01)
    v.equal("CH0J 차단값 매핑", AdapterControlKey.ch0j.disableValue, 0x01)
    v.equal("CHIE 차단값 매핑", AdapterControlKey.chie.disableValue, 0x08)
    v.equal("bfF0 off", SMCChargeValues.firmwareLimitOff, 0x00)
    v.equal("bfF0 on", SMCChargeValues.firmwareLimitOn, 0x02)
    v.equal("MagSafe system", MagSafeLEDState.system.rawValue, 0x00)
    v.equal("MagSafe off", MagSafeLEDState.off.rawValue, 0x01)
    v.equal("MagSafe green", MagSafeLEDState.green.rawValue, 0x03)
    v.equal("MagSafe orange", MagSafeLEDState.orange.rawValue, 0x04)
    v.equal("키 폭 기대치: CHTE=4", SMCKeys.expectedWidths[SMCKeys.chargeInhibitTahoe], 4)
    v.equal("키 폭 기대치: CH0B=1", SMCKeys.expectedWidths[SMCKeys.chargeInhibitA], 1)
    v.equal("키 폭 기대치: CHIE=1", SMCKeys.expectedWidths[SMCKeys.adapterInhibitTahoe], 1)
    v.equal("키 폭 기대치: bfD0=4", SMCKeys.expectedWidths[SMCKeys.firmwareLimitUpper], 4)

    return sweptCases
}

// MARK: - 배터리 속성 해석

func runBatteryParserChecks(_ v: Verifier) -> Int {
    var sweptCases = 0

    v.section("배터리 속성 해석 (Apple Silicon)")

    let info = BatteryPropertyParser.parse(Make.batteryProperties(percent: 78))
    v.close("percent", info.percent, 78)
    v.close("precisePercent (3886/4982 mAh)", info.precisePercent, 78.0, tolerance: 0.3)
    v.equal("cycleCount", info.cycleCount, 142)
    v.close("healthPercent 4982/5300", info.healthPercent ?? -1, 94.0, tolerance: 0.1)
    v.close("voltage", info.voltage ?? -1, 12.45, tolerance: 0.001)
    v.close("amperage", info.amperage ?? -1, 1.82, tolerance: 0.001)
    v.close("temperature", info.temperature ?? -1, 30.55, tolerance: 0.001)
    v.close("batteryWatts (V×A)", info.batteryWatts ?? -1, 22.659, tolerance: 0.01)
    v.expect("isCharging", info.isCharging)
    v.expect("isPluggedIn", info.isPluggedIn)
    v.expect("batteryInstalled", info.batteryInstalled)
    v.expect("isDischarging 아님", !info.isDischarging)
    v.equal("designCapacity", info.designCapacity, 5300)
    v.equal("nominalCapacity", info.nominalCapacity, 4982)

    v.section("배터리 속성 해석 (경계·이상값)")

    // 0~100% 전수 확인
    var percentViolations: [String] = []
    for percent in 0...100 {
        sweptCases += 1
        let parsed = BatteryPropertyParser.parse(Make.batteryProperties(percent: percent))
        if abs(parsed.percent - Double(percent)) > 0.001 {
            percentViolations.append("\(percent) → \(parsed.percent)")
        }
        if parsed.precisePercent < 0 || parsed.precisePercent > 100 {
            percentViolations.append("\(percent) → precise \(parsed.precisePercent) 범위 밖")
        }
        if abs(parsed.precisePercent - Double(percent)) > 1.0 {
            percentViolations.append("\(percent) → precise \(parsed.precisePercent) 편차 과다")
        }
    }
    v.sweep("percent 0~100 왕복 + precise 범위", cases: 101, violations: percentViolations)

    // 온도 필터: -20 < °C < 120 만 받아들인다
    var temperatureViolations: [String] = []
    for centi in stride(from: -6000, through: 15000, by: 100) {
        sweptCases += 1
        let parsed = BatteryPropertyParser.parse(["Temperature": centi])
        let celsius = Double(centi) / 100
        let shouldAccept = celsius > -20 && celsius < 120
        if shouldAccept && parsed.temperature == nil {
            temperatureViolations.append("\(celsius)°C 를 버렸다")
        }
        if !shouldAccept && parsed.temperature != nil {
            temperatureViolations.append("\(celsius)°C 를 받아들였다")
        }
    }
    v.sweep("온도 필터 -60~150°C", cases: 211, violations: temperatureViolations)

    // 남은 시간 sanitize: 0 < 분 < 2880
    var minuteViolations: [String] = []
    for minutes in [-100, -1, 0, 1, 60, 1000, 2879, 2880, 5000, 65535] {
        sweptCases += 1
        let parsed = BatteryPropertyParser.parse(["AvgTimeToFull": minutes])
        let shouldAccept = minutes > 0 && minutes < 2880
        if shouldAccept != (parsed.minutesToFull != nil) {
            minuteViolations.append("\(minutes) → \(String(describing: parsed.minutesToFull))")
        }
    }
    v.sweep("남은 시간 sanitize", cases: 10, violations: minuteViolations)

    // BatteryData.StateOfCharge 우선순위
    let withSoC = BatteryPropertyParser.parse([
        "CurrentCapacity": 50, "MaxCapacity": 100,
        "BatteryData": ["StateOfCharge": 63] as [String: Any],
    ])
    v.close("StateOfCharge 가 우선", withSoC.percent, 63)

    let outOfRangeSoC = BatteryPropertyParser.parse([
        "CurrentCapacity": 50, "MaxCapacity": 100,
        "BatteryData": ["StateOfCharge": 150] as [String: Any],
    ])
    v.close("범위 밖 StateOfCharge 는 무시", outOfRangeSoC.percent, 50)

    // 인텔식 (MaxCapacity 가 mAh)
    let intel = BatteryPropertyParser.parse(["CurrentCapacity": 2500, "MaxCapacity": 5000])
    v.close("mAh 비율 계산", intel.percent, 50)
    let intelZero = BatteryPropertyParser.parse(["CurrentCapacity": 2500, "MaxCapacity": 0])
    v.close("MaxCapacity 0 이면 0%", intelZero.percent, 0)

    // 100% 를 넘는 보고를 클램프하는지
    let over = BatteryPropertyParser.parse(["CurrentCapacity": 150, "MaxCapacity": 100])
    v.close("100% 초과 보고 클램프", over.percent, 100)
    let under = BatteryPropertyParser.parse(["CurrentCapacity": -20, "MaxCapacity": 100])
    v.close("음수 보고 클램프", under.percent, 0)

    // 빈 딕셔너리 (배터리를 못 읽는 상황)
    let empty = BatteryPropertyParser.parse([:])
    v.close("빈 딕셔너리 percent", empty.percent, 0)
    v.isNil("빈 딕셔너리 health", empty.healthPercent)
    v.isNil("빈 딕셔너리 temperature", empty.temperature)
    v.isNil("빈 딕셔너리 voltage", empty.voltage)
    v.isNil("빈 딕셔너리 batteryWatts", empty.batteryWatts)
    v.expect("빈 딕셔너리 기본 installed=true", empty.batteryInstalled)
    v.expect("빈 딕셔너리 plugged=false", !empty.isPluggedIn)

    // 어댑터 정보
    let adapter = BatteryPropertyParser.parse([
        "AdapterDetails": ["Watts": 96, "Name": "96W USB-C Power Adapter"] as [String: Any],
    ])
    v.equal("어댑터 W", adapter.adapterWatts, 96)
    v.equal("어댑터 이름", adapter.adapterName, "96W USB-C Power Adapter")
    let adapterDesc = BatteryPropertyParser.parse([
        "AdapterDetails": ["Description": "usb-c"] as [String: Any],
    ])
    v.equal("이름 없으면 Description", adapterDesc.adapterName, "usb-c")

    // 방전 판정
    let discharging = BatteryPropertyParser.parse([
        "Amperage": -1500, "Voltage": 11_800, "ExternalConnected": false,
    ])
    v.expect("음수 전류 → 방전", discharging.isDischarging)
    v.close("방전 시 W 는 음수", discharging.batteryWatts ?? 0, -17.7, tolerance: 0.1)

    // NSNumber / Bool 혼용
    let numberTypes = BatteryPropertyParser.parse([
        "CurrentCapacity": NSNumber(value: 42),
        "MaxCapacity": NSNumber(value: 100),
        "IsCharging": NSNumber(value: true),
    ])
    v.close("NSNumber percent", numberTypes.percent, 42)
    v.expect("NSNumber Bool", numberTypes.isCharging)

    return sweptCases
}
