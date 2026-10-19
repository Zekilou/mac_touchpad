import SwiftUI
import GestureEngine

// MARK: - 报告窗口
//
// 一个表单三种形态共用：
//   1. 错误弹窗（有已捕获的错误）
//   2. 崩溃报告（上次异常退出）
//   3. 主动上报（用户从菜单栏/设置页打开，可能没有任何已捕获错误）
//
// 设计原则：所有「要发出去的东西」都默认可见、可勾选、可取消；
// 用户点「发送」之前不会发任何字节。

struct ReportView: View {
    @EnvironmentObject var center: ReportCenter
    let manual: Bool

    @State private var user = UserInfo.empty
    @State private var includeLogs = true
    @State private var includeCrash = true
    @State private var includeConfig = false
    @State private var selected: Set<String> = []
    @State private var showDetails = false
    @State private var showConsentNote = false

    var body: some View {
        VStack(spacing: 0) {
            switch center.uploadStatus {
            case .done(let id):  successView(id: id)
            case .sending:       sendingView
            default:             formView
            }
        }
        .frame(minWidth: 460, idealWidth: 460, minHeight: 560)
        .onAppear {
            selected = Set(center.issues.map(\.fingerprint))
            if manual && center.issues.isEmpty {
                // 主动上报时默认不带任何日志？不——日志恰恰最有用，但用户可取消
                includeLogs = true
            }
        }
    }

    // MARK: - 表单

    private var formView: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if center.issues.isEmpty && manual {
                        emptyManualHint
                    } else {
                        issueList
                    }

                    userFields
                    collectionOptions
                    privacyNote
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }

            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: headerIcon)
                    .foregroundStyle(headerColor)
                    .font(.system(size: 18))
                Text(headerTitle)
                    .font(.headline)
                Spacer()
            }
            Text(headerSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var headerIcon: String {
        if manual { return "exclamationmark.bubble" }
        if center.issues.contains(where: { $0.severity == .fatal }) { return "exclamationmark.triangle.fill" }
        return "exclamationmark.circle"
    }

    private var headerColor: Color {
        if center.issues.contains(where: { $0.severity == .fatal }) { return .red }
        if center.issues.contains(where: { $0.severity == .error }) { return .orange }
        return .accentColor
    }

    private var headerTitle: String {
        if manual { return L10n.tr("报告问题", "Report a Problem") }
        let n = center.issues.count
        return n > 0
            ? L10n.tr("出现了 \(n) 个问题", "\(n) issue(s) detected")
            : L10n.tr("出现了问题", "Something went wrong")
    }

    private var headerSubtitle: String {
        if manual {
            return L10n.tr("描述你遇到的问题，并选择要一并发送的诊断信息。发送前不会上传任何内容。",
                           "Describe the problem and pick what diagnostics to attach. Nothing is sent until you press Send.")
        }
        return L10n.tr("是否把这次的错误报告发送给开发者？发送前不会上传任何内容。",
                       "Send this error report to the developer? Nothing is uploaded until you press Send.")
    }

    private var emptyManualHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(L10n.tr("当前没有捕获到错误。可以只发送你填写的描述。",
                         "No errors captured. You can send just your description."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    // MARK: - 错误列表

    private var issueList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("将发送的错误", "Errors to send"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(center.issues) { issue in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { selected.contains(issue.fingerprint) },
                        set: { on in
                            if on { selected.insert(issue.fingerprint) }
                            else { selected.remove(issue.fingerprint) }
                        }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(issue.message)
                            .font(.system(size: 12))
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            severityTag(issue.severity)
                            if issue.count > 1 {
                                Text("×\(issue.count)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Text(ReportJSON.clockFormatter.string(from: issue.firstSeen))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(issue.domain + "/" + issue.code)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func severityTag(_ severity: ReportSeverity) -> some View {
        Text(severity.localizedName)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(severityColor(severity).opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundColor(severityColor(severity))
    }

    private func severityColor(_ severity: ReportSeverity) -> Color {
        switch severity {
        case .fatal: return .red
        case .error: return .orange
        case .warning: return .yellow
        case .info: return .secondary
        }
    }

    // MARK: - 用户填写

    private var userFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("补充说明（可选）", "Details (optional)"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(L10n.tr("描述问题，例如「左侧 Force 按压后音量不变」",
                              "Describe the problem, e.g. \"Force press on left edge doesn't change volume\""),
                      text: $user.description, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            TextField(L10n.tr("复现步骤（可选）", "Steps to reproduce (optional)"),
                      text: $user.steps, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...3)

            TextField(L10n.tr("联系方式（可选，方便回复你）", "Contact (optional)"),
                      text: $user.contact)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - 收集项

    private var collectionOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.tr("随报告发送", "Attach to report"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(showDetails ? L10n.tr("收起", "Hide") : L10n.tr("查看内容", "Preview")) {
                    showDetails.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            optionRow(title: L10n.tr("环境信息", "Environment"),
                      detail: L10n.tr("版本、机型、系统、权限状态、触控板设备",
                                      "Version, model, OS, permissions, trackpad device"),
                      isOn: .constant(true), enabled: false)
            optionRow(title: L10n.tr("错误详情", "Error details"),
                      detail: L10n.tr("错误信息、次数、时间与调用位置",
                                      "Messages, counts, timestamps, call sites"),
                      isOn: .constant(true), enabled: false)
            optionRow(title: L10n.tr("引擎日志", "Engine logs"),
                      detail: L10n.tr("最近 300 条运行日志，已脱敏",
                                      "Last 300 log lines, redacted"),
                      isOn: $includeLogs, enabled: true)
            optionRow(title: L10n.tr("崩溃日志", "Crash logs"),
                      detail: L10n.tr("上次异常退出的记录（若有）",
                                      "Record of the previous abnormal exit, if any"),
                      isOn: $includeCrash, enabled: true)
            optionRow(title: L10n.tr("配置快照", "Config snapshot"),
                      detail: L10n.tr("包含你自己起的手势名称，默认不发送",
                                      "Includes your custom gesture names; off by default"),
                      isOn: $includeConfig, enabled: true)

            if showDetails {
                previewBox
            }
        }
    }

    private func optionRow(title: String, detail: String,
                           isOn: Binding<Bool>, enabled: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!enabled)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .opacity(enabled ? 1 : 0.65)
    }

    /// 预览：真的把日志/崩溃文本读出来给用户看（不是"我们保证会脱敏"）
    private var previewBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            let logs = includeLogs ? DiagnosticsCollector.collectLogs(maxBytes: 8 * 1024) : ""
            let crash = includeCrash ? (DiagnosticsCollector.collectCrash(maxBytes: 4 * 1024) ?? "") : ""

            if logs.isEmpty && crash.isEmpty {
                Text(L10n.tr("暂无可预览内容。", "Nothing to preview."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text((logs.isEmpty ? "" : "── 日志 ──\n" + logs)
                     + (crash.isEmpty ? "" : "\n── 崩溃 ──\n" + crash))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(14)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            }
        }
    }

    // MARK: - 隐私说明

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("不会发送：用户名、主机名、序列号、屏幕内容、你的配置文件（除非你勾选）。",
                         "Never sent: username, hostname, serial number, screen contents, or your config (unless you tick it)."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(L10n.tr("发送到 \(ReportScope.endpoint.host ?? "")，仅用于定位问题。",
                         "Sent to \(ReportScope.endpoint.host ?? ""), used only to diagnose issues."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 底部按钮

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button(L10n.tr("稍后", "Later")) { center.dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                Button(L10n.tr("不再提示", "Don't Ask Again")) { center.mute() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(L10n.tr("本次运行内不再为该问题弹窗（仍保留在本地）",
                                  "Don't prompt for this issue again this session (still kept locally)"))

                Spacer()

                if center.pendingUploadCount > 0 {
                    Text(L10n.tr("\(center.pendingUploadCount) 份待发送", "\(center.pendingUploadCount) pending"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(L10n.tr("发送报告", "Send Report")) { send() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty && user.description.isEmpty && center.issues.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if case .failed(let message) = center.uploadStatus {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
        }
    }

    private func send() {
        let trigger: ReportTrigger = manual ? .manual : .error
        guard let document = center.buildDocument(
            trigger: trigger,
            selectedFingerprints: selected,
            user: user,
            includeLogs: includeLogs,
            includeCrash: includeCrash,
            includeConfig: includeConfig) else {
            return
        }
        center.send(document)
    }

    // MARK: - 结果态

    private var sendingView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(L10n.tr("正在发送…", "Sending…"))
                .font(.callout)
            Text(L10n.tr("报告已保存在本地，发送失败也不会丢失。",
                         "The report is saved locally; nothing is lost if sending fails."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func successView(id: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text(L10n.tr("报告已发送", "Report sent"))
                .font(.headline)
            Text(L10n.tr("谢谢！报告编号 \(id.prefix(8))",
                         "Thanks! Report ID \(id.prefix(8))"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L10n.tr("你可以继续正常使用，窗口可以关闭了。",
                         "You can close this window and keep using the app."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L10n.tr("关闭", "Close")) {
                ReportWindowController.shared.close()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
