import SwiftUI

struct PerkyPanelView: View {
    @ObservedObject var model: PerkyModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingOptions = false
    @State private var isShowingResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            statusHeader

            if model.isRunning {
                if model.isLidModeActive {
                    lidModeToggle
                }
                runningControls
            } else {
                idleControls
            }

            if shouldShowRecoveryNotice {
                recoveryNotice
            } else if let failure = model.failureMessage {
                failureNotice(failure)
            }

            options

            HStack {
                Spacer()
                Button(role: .destructive) {
                    model.requestQuit()
                } label: {
                    Label("退出", systemImage: "power")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .help("停止计时并恢复临时修改的系统设置后退出")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.isRunning)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isShowingOptions)
        .confirmationDialog(
            "调整剩余时间？",
            isPresented: $isShowingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认调整") { model.applySelectedDurationAsRemainingTime() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("剩余时间将设为 \(model.selectedDuration ?? 0) 分钟。")
        }
        .confirmationDialog(
            "启用合盖运行？",
            isPresented: lidExplanationPresentation,
            titleVisibility: .visible
        ) {
            Button("继续设置") { model.confirmLidModeSetup() }
            Button("取消", role: .cancel) { model.cancelLidModeSetup() }
        } message: {
            Text("合盖模式会临时修改整台 Mac 的睡眠设置，并在停止或到期时恢复。实际效果取决于机型；使用电池时会在低电量时停止。")
        }
        .confirmationDialog(
            "在电池供电下继续？",
            isPresented: batteryConfirmationPresentation,
            titleVisibility: .visible
        ) {
            Button("继续并启动") { model.confirmStartOnBattery() }
            Button("取消", role: .cancel) { model.cancelStartOnBattery() }
        } message: {
            Text(model.batteryConfirmationMessage)
        }
        .confirmationDialog(
            "退出并恢复系统设置？",
            isPresented: quitConfirmationPresentation,
            titleVisibility: .visible
        ) {
            Button("停止并退出", role: .destructive) { model.confirmQuit() }
            Button("继续运行", role: .cancel) { model.cancelQuit() }
        } message: {
            Text("Perky 会停止计时并恢复临时修改的系统设置与屏幕亮度。")
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Perky")
                    .font(.headline)
                Text(stateTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }

            Spacer(minLength: 8)

            if model.isRunning {
                Label(
                    model.isLidModeActive ? "合盖" : "普通",
                    systemImage: model.isLidModeActive ? "laptopcomputer.and.arrow.down" : "sun.max"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var stateTitle: String {
        if model.isStarting { return "正在启动" }
        if model.isStopping { return "正在停止" }
        if model.isRunning { return "保持唤醒中" }
        return "未运行"
    }

    private var statusColor: Color {
        if model.failureMessage != nil
            || model.isStopping
            || model.helperHasConflict
            || model.helperRecoveryStatusUncertain {
            return .orange
        }
        return model.isRunning ? .green : .secondary
    }

    private var idleControls: some View {
        VStack(alignment: .leading, spacing: 13) {
            durationPicker
            lidModeToggle

            if model.isLidModeEnabled && !model.helperIsEnabled {
                HStack(spacing: 7) {
                    Label(
                        model.helperNeedsApproval && model.helperCanRegister
                            ? "等待系统批准"
                            : (model.helperCanRegister ? "需要系统授权" : "当前版本无法批准"),
                        systemImage: "exclamationmark.circle"
                    )
                    .help(model.helperStatusMessage)
                    .accessibilityHint(model.helperStatusMessage)

                    Spacer(minLength: 4)

                    if model.helperNeedsApproval && model.helperCanRegister {
                        Button("打开设置") { model.openLidHelperSettings() }
                            .buttonStyle(.borderless)
                        Button("重新检查") { model.recheckHelperRecoveryStatus() }
                            .buttonStyle(.borderless)
                    } else if model.helperCanRegister {
                        Button("授权") { model.registerLidHelper() }
                            .buttonStyle(.borderless)
                    } else {
                        Button("打开登录项") { model.openLidHelperSettings() }
                            .buttonStyle(.borderless)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !model.helperCanRegister {
                    Text("需 Apple 信任签名后，Perky 才会出现在批准列表中。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                model.start()
            } label: {
                Label("开始保持唤醒", systemImage: "sun.max")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.selectedDuration == nil || model.isStarting || model.isStopping)
            .accessibilityHint("普通模式仅防止空闲睡眠；合盖模式按你的设置运行")
        }
    }

    private var runningControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(model.formattedRemaining(at: context.date))
                    .font(.system(size: 38, weight: .medium, design: .rounded).monospacedDigit())
                    .accessibilityLabel("剩余时间")
                    .accessibilityValue(model.formattedRemaining(at: context.date))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 9) {
                Button {
                    model.extend(by: 15)
                } label: {
                    Label("延长 15 分钟", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isStopping)
                .keyboardShortcut(.defaultAction)

                Button("停止", role: .destructive) {
                    model.stopManually()
                }
                .buttonStyle(.bordered)
                .disabled(model.isStopping)
            }

            Button("调整剩余时间…") {
                isShowingResetConfirmation = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(model.isStopping || model.selectedDuration == nil)
        }
    }

    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("保持时长")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("保持时长", selection: model.durationChoice) {
                Text("15 分").tag("15")
                Text("30 分").tag("30")
                Text("60 分").tag("60")
                Text("自定").tag("custom")
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("保持时长")
            .accessibilityHint("选择快捷时长或自定义时长")
            .disabled(model.isStarting || model.isStopping)

            if model.isCustomDurationSelected {
                HStack(spacing: 7) {
                    TextField("分钟", text: $model.customMinutesText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 86)
                        .accessibilityLabel("自定义时长，分钟")
                        .accessibilityHint("请输入 1 到 1440 之间的整数")
                        .onChange(of: model.customMinutesText) {
                            model.customDurationDidChange()
                        }
                    Text("分钟")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = model.customDurationError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var lidModeToggle: some View {
        Toggle(isOn: Binding(
            get: { model.isLidModeEnabled || model.isLidModeActive },
            set: { enabled in
                guard !enabled || !model.isRunning else { return }
                if enabled { model.requestLidModeEnable() }
                else { model.disableLidMode() }
            }
        )) {
            Label("合盖运行", systemImage: "laptopcomputer.and.arrow.down")
        }
        .toggleStyle(.switch)
        .accessibilityHint("开启后需允许恢复助手；系统睡眠设置会在停止或到期时恢复")
    }

    private var options: some View {
        DisclosureGroup(isExpanded: $isShowingOptions) {
            VStack(alignment: .leading, spacing: 12) {
                if model.isLidModeEnabled {
                    lidOptions
                    Divider()
                }

                brightnessOptions
                Divider()

                Toggle(
                    "到期时发送通知",
                    isOn: Binding(
                        get: { model.notificationsEnabled },
                        set: { model.updateNotifications($0) }
                    )
                )
                .accessibilityHint("需要在系统设置中允许通知")

                if let message = model.notificationMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Button("检查状态") { model.runDiagnostics() }
                        .buttonStyle(.borderless)
                    if let message = model.diagnosticsMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(message)
                    }
                }

            }
            .padding(.top, 9)
        } label: {
            Label("选项", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.medium))
        }
    }

    private var lidOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(
                    model.currentLidClosed == true ? "已合盖" : (model.currentLidClosed == false ? "已开盖" : "合盖状态未知"),
                    systemImage: model.currentLidClosed == true ? "laptopcomputer.and.arrow.down" : "laptopcomputer"
                )
                Spacer(minLength: 4)
                Text(powerSummary)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Text(model.lidReadinessMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isLidModeActive && model.currentClamshellWillSleep == true {
                Label("本机仍可能在合盖时睡眠", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(model.lidModeStatusMessage)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("低电量停止")
                    Spacer()
                    Text("\(model.batteryThresholdPercent)%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.batteryThresholdPercent) },
                        set: { model.setBatteryThresholdPercent(Int($0.rounded())) }
                    ),
                    in: 5...50,
                    step: 1
                )
                .accessibilityLabel("低电量自动停止阈值")
                .accessibilityHint("活动会话沿用启动时的阈值")
                .help("活动会话沿用启动时的阈值")
                .disabled(
                    model.isLidModeActive
                        || model.isStarting
                        || model.isStopping
                        || model.helperRecoveryIdentifier != nil
                        || model.helperRecoveryStatusUncertain
                )
            }
        }
    }

    private var powerSummary: String {
        if model.isOnACPower { return "电源已连接" }
        if let battery = model.currentBatteryPercent { return "电池 \(battery)%" }
        return "电量未知"
    }

    private var brightnessOptions: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(
                "合盖时调暗内建屏幕",
                isOn: Binding(
                    get: { model.brightnessAutomationEnabled },
                    set: { model.setBrightnessAutomationEnabled($0) }
                )
            )
            .disabled(!model.isBrightnessAvailable)
            .accessibilityHint("开盖或停止后恢复原亮度")
            .help("只控制 Mac 内建屏幕；开盖或停止后恢复原亮度")

            if model.isBrightnessAvailable && model.brightnessAutomationEnabled {
                HStack {
                    Text("目标亮度")
                    Spacer()
                    Text("\(model.brightnessTargetPercent)%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.brightnessTargetPercent) },
                        set: { model.setBrightnessTargetPercent(Int($0.rounded())) }
                    ),
                    in: 5...30,
                    step: 1
                )
                .accessibilityLabel("合盖时目标亮度")
            }

            if !model.isBrightnessAvailable {
                Text(model.brightnessStatusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shouldShowRecoveryNotice: Bool {
        model.helperHasConflict
            || model.helperRecoveryStatusUncertain
            || (model.helperRecoveryIdentifier != nil
                && !model.isLidModeActive
                && !model.isRunning
                && !model.isStarting)
    }

    private var recoveryNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                model.helperHasConflict
                    ? "系统设置需要处理"
                    : (model.helperRecoveryStatusUncertain ? "恢复状态未知" : "待恢复的系统设置"),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption.weight(.semibold))

            if let deadline = model.helperRecoveryDeadline {
                Text("自动恢复：\(deadline.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if model.helperHasConflict || model.helperRecoveryStatusUncertain,
               let message = model.helperRecoveryMessage ?? model.failureMessage {
                Text(message)
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.helperRecoveryStatusUncertain {
                Text("请检查恢复助手后再启动或退出。")
                    .font(.caption2)
            }

            if model.helperHasConflict {
                if model.helperRecoveryIdentifier != nil {
                    HStack(spacing: 8) {
                        Button("恢复原设置") {
                            model.resolvePowerSettingConflict(restoreOriginal: true)
                        }
                        .buttonStyle(.bordered)
                        Button("保留当前") {
                            model.resolvePowerSettingConflict(restoreOriginal: false)
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Button("保留当前并清除记录") {
                        model.keepCurrentSystemSettingAndClearUnreadableRecord()
                    }
                    .buttonStyle(.bordered)
                }
            } else if model.helperRecoveryIdentifier != nil {
                Button("立即恢复") {
                    model.restoreInterruptedLidSessionNow()
                }
                .buttonStyle(.bordered)
                .disabled(model.isRunning || model.isStarting || model.isStopping)
            } else {
                Button("重新检查") { model.recheckHelperRecoveryStatus() }
                    .buttonStyle(.borderless)
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }

    private func failureNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isStopping {
                    Button("重试停止") { model.retryStop() }
                        .buttonStyle(.borderless)
                } else if model.helperNeedsApproval && model.helperCanRegister {
                    HStack(spacing: 10) {
                        Button("重新打开登录项设置") { model.openLidHelperSettings() }
                            .buttonStyle(.borderless)
                        Button("已允许，重新检查") { model.recheckHelperRecoveryStatus() }
                            .buttonStyle(.borderless)
                    }
                } else if model.isLidModeActive && !model.isLidModeEnabled {
                    Button("重试关闭合盖模式") { model.disableLidMode() }
                        .buttonStyle(.borderless)
                } else if model.helperCanRegister || !model.isLidModeEnabled {
                    Button("重试") { model.start() }
                        .buttonStyle(.borderless)
                        .disabled(model.selectedDuration == nil)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }

    private var lidExplanationPresentation: Binding<Bool> {
        Binding(
            get: { model.isShowingLidExplanation },
            set: { if !$0 { model.cancelLidModeSetup() } }
        )
    }

    private var batteryConfirmationPresentation: Binding<Bool> {
        Binding(
            get: { model.isShowingBatteryConfirmation },
            set: { if !$0 { model.cancelStartOnBattery() } }
        )
    }

    private var quitConfirmationPresentation: Binding<Bool> {
        Binding(
            get: { model.isShowingQuitConfirmation },
            set: { if !$0 { model.cancelQuit() } }
        )
    }
}
