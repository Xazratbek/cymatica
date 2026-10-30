import AppKit
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "Umumiy"
        case .appearance: "Ko'rinish"
        case .about: "Haqida"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "sparkles"
        case .about: "info.circle"
        }
    }
}

/// Selected tab, shared so the menu can open a specific pane.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selectedTab: SettingsTab? = .general
    private init() {}
}

private enum AppVersion {
    static let displayString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "Versiya \(version) (\(build))"
    }()
}

// MARK: - Root

struct SettingsView: View {
    let actions: SettingsActions
    @State private var navigation = SettingsNavigation.shared
    @State private var history: [SettingsTab] = [.general]
    @State private var historyIndex = 0
    @State private var isHistoryNavigation = false

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $navigation.selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .foregroundStyle(.primary)
                        .tag(tab)
                }
                Text(AppVersion.displayString)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fontDesign(.monospaced)
                    .padding(.vertical, 8)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.sidebar)
            .scrollEdgeEffectStyleSoftIfAvailable()
            .navigationTitle("Sozlamalar")
            .frame(width: 200)
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(for: navigation.selectedTab ?? .general)
        }
        .navigationTitle("Sozlamalar")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 660, minHeight: 540)
        .toolbar {
            // Back/forward also makes SwiftUI create an NSToolbar, which the Liquid
            // Glass title bar needs.
            ToolbarItemGroup(placement: .navigation) {
                Button { move(by: -1) } label: { Image(systemName: "chevron.left") }
                    .disabled(historyIndex == 0)
                Button { move(by: 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(historyIndex >= history.count - 1)
            }
        }
        .onChange(of: navigation.selectedTab) { _, tab in
            guard !isHistoryNavigation, let tab, history[historyIndex] != tab else { return }
            history = Array(history.prefix(historyIndex + 1)) + [tab]
            historyIndex = history.count - 1
        }
    }

    @ViewBuilder
    private func detail(for tab: SettingsTab) -> some View {
        Group {
            switch tab {
            case .general: GeneralPane(actions: actions)
            case .appearance: AppearancePane(actions: actions)
            case .about: AboutPane()
            }
        }
        .navigationTitle(tab.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func move(by step: Int) {
        let target = historyIndex + step
        guard history.indices.contains(target) else { return }
        isHistoryNavigation = true
        historyIndex = target
        navigation.selectedTab = history[target]
        DispatchQueue.main.async { isHistoryNavigation = false }
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    let actions: SettingsActions
    @AppStorage("mode") private var mode = DisplayMode.mixed.rawValue
    @AppStorage("followRhythm") private var followRhythm = false
    @AppStorage("autoMode") private var autoMode = true
    @AppStorage("idleSeconds") private var idleSeconds = 20.0
    @AppStorage("showWithoutMusic") private var showWithoutMusic = false
    @AppStorage("respectVideo") private var respectVideo = true
    @AppStorage("keyboardDismisses") private var keyboardDismisses = true
    @State private var loginStatus = SMAppService.mainApp.status

    var body: some View {
        Form {
            Section("Rejim") {
                Picker("Qum nimani chizadi", selection: $mode) {
                    ForEach(DisplayMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(modeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(isOn: $followRhythm) {
                    described("Musiqa ritmiga moslashsin",
                              "Qum har zarbda sakraydi, naqsh zarb bilan almashadi, kamera tezligi musiqaning kuchiga qarab o'zgaradi. Soat raqamlari zarb bilan titraydi.")
                }
                .toggleStyle(.switch)
            }

            Section("Avtomatik yoqilish") {
                Toggle(isOn: $autoMode) {
                    described("Avtomatik yoqilsin", "Mac tegilmay turganda plastinka sekin paydo bo'ladi.")
                }
                .toggleStyle(.switch)
                LabeledContent("Kutish vaqti") {
                    HStack(spacing: 12) {
                        Slider(value: rounded($idleSeconds, to: 5), in: 5...300)
                            .frame(width: 180)
                        Text(Self.duration(idleSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
                .disabled(!autoMode)
                Toggle(isOn: $showWithoutMusic) {
                    described("Musiqa bo'lmasa ham yoqilsin",
                              "Telefondagi always on display kabi: soat doim ko'rinadi. Ekran uyg'oq turadi, batareya ko'proq sarflanadi.")
                }
                .toggleStyle(.switch)
                .disabled(!autoMode)
                Toggle(isOn: $respectVideo) {
                    described("Video ko'rilayotganda yoqilmasin",
                              "Boshqa ilova ekranni uyg'oq ushlab tursa (odatda video), plastinka chiqmaydi.")
                }
                .toggleStyle(.switch)
                .disabled(!autoMode)
            }

            Section("O'chirish") {
                Toggle(isOn: Binding(get: { !keyboardDismisses }, set: { keyboardDismisses = !$0 })) {
                    described("Klaviatura bosilganda o'chmasin",
                              "Plastinka faqat trackpad yoki sichqoncha tegilganda yopiladi.")
                }
                .toggleStyle(.switch)
            }

            Section("Ovoz") {
                LabeledContent("Manba") {
                    Text(actions.audioStatus())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                Button("Maxfiylik sozlamalarini ochish") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }
                .controlSize(.small)
            }

            Section("Tizim") {
                Toggle(isOn: loginBinding) {
                    described("Mac yoqilganda ishga tushsin", "Menyu satrida o'zi paydo bo'ladi.")
                }
                .toggleStyle(.switch)
                if loginStatus == .requiresApproval {
                    LabeledContent("macOS tasdig'ini kutmoqda") {
                        Button("Login Items'ni ochish") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }

    private var modeDescription: String {
        switch DisplayMode(rawValue: mode) ?? .mixed {
        case .music: "Qum musiqaning notasiga qarab Xladni naqshlarini chizadi."
        case .clock: "Qum hozirgi vaqtni chizadi. Soniya almashsa, faqat o'sha raqamning qumi sakraydi."
        case .mixed: "Musiqa chalinsa Xladni naqshlari, musiqa to'xtasa qum soatga aylanadi."
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total < 60 ? "\(total) s" : total % 60 == 0 ? "\(total / 60) daq" : "\(total / 60) daq \(total % 60) s"
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginStatus == .enabled || loginStatus == .requiresApproval },
            set: { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("Cymatica: login item: \(error)")
                }
                loginStatus = SMAppService.mainApp.status
            })
    }
}

private struct AppearancePane: View {
    let actions: SettingsActions
    @AppStorage("clockStyle") private var clockStyle = ClockStyle.digital.rawValue
    @AppStorage("showSeconds") private var showSeconds = true
    @AppStorage("shape") private var shape = PlateField.Shape.square.rawValue
    @AppStorage("grainCount") private var grainCount = 100_000
    @AppStorage("showCaption") private var showCaption = true
    @AppStorage("placement") private var placement = Placement.center.rawValue
    @AppStorage("plateSize") private var plateSize = 1.0
    @AppStorage("framesPerSecond") private var framesPerSecond = 60
    @AppStorage("screenID") private var screenID = 0
    /// The grain slider only commits when released; reallocating on every tick is wasteful.
    @State private var grainDraft = 100_000.0

    var body: some View {
        Form {
            Section("Soat") {
                Picker("Ko'rinishi", selection: $clockStyle) {
                    Text("Raqamli").tag(ClockStyle.digital.rawValue)
                    Text("Doira").tag(ClockStyle.analog.rawValue)
                    Text("Halqalar").tag(ClockStyle.rings.rawValue)
                }
                .pickerStyle(.segmented)
                Toggle("Soniyalarni ko'rsatish", isOn: $showSeconds)
                    .toggleStyle(.switch)
            }

            Section("Plastinka") {
                Picker("Shakl", selection: $shape) {
                    Text("Kvadrat").tag(PlateField.Shape.square.rawValue)
                    Text("Doira").tag(PlateField.Shape.circle.rawValue)
                }
                .pickerStyle(.segmented)
                LabeledContent("Qum miqdori") {
                    HStack(spacing: 12) {
                        Slider(value: rounded($grainDraft, to: 10_000), in: 20_000...300_000) { editing in
                            if !editing { grainCount = Int(grainDraft) }
                        }
                        .frame(width: 180)
                        Text("\(Int(grainDraft) / 1000) ming")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
                Toggle(isOn: $showCaption) {
                    described("Nota va chastotani ko'rsatish",
                              "Naqsh almashganda pastda bir necha soniya xira yozuv chiqadi.")
                }
                .toggleStyle(.switch)
            }

            Section("Joylashuv") {
                LabeledContent("Ekrandagi joyi") {
                    PlacementGrid(selection: $placement)
                }
                LabeledContent("O'lchami") {
                    HStack(spacing: 12) {
                        Slider(value: rounded($plateSize, to: 0.05), in: 0.4...1.2)
                            .frame(width: 180)
                        Text("\(Int((plateSize * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
                Picker("Qaysi ekranda", selection: $screenID) {
                    Text("Avtomatik (Mac ekrani)").tag(0)
                    ForEach(NSScreen.screens, id: \.displayID) { screen in
                        Text(screen.localizedName).tag(Int(screen.displayID))
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("Kadr tezligi", selection: $framesPerSecond) {
                    Text("60 FPS").tag(60)
                    Text("120 FPS").tag(120)
                }
                .pickerStyle(.segmented)
            }

            Section {
                HStack(spacing: 8) {
                    Button("Hozir ko'rish", action: actions.showNow)
                        .controlSize(.small)
                    Button("Qumni qayta sepish", action: actions.rescatter)
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear { grainDraft = Double(grainCount) }
    }
}

private struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cymatica").font(.title2.weight(.semibold))
                    Text(AppVersion.displayString).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section("Bu nima") {
                Text("Qora tebranuvchi plastinkadagi oltin qum. Qo'shiqning asosiy notasi plastinkaning tebranish shaklini tanlaydi, qum esa qimirlamaydigan chiziqlarga yig'iladi. Akkord almashsa, qum sakrab yangi naqsh hosil qiladi.")
                Text("1787-yilda Ernst Xladni skripka kamoni bilan qum sepilgan plastinkada xuddi shu naqshlarni ko'rsatgan. Bu bezak emas, shu fizikaning simulyatsiyasi.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

// MARK: - Helpers

/// Snaps a slider to `step` without the tick marks a `step:` slider draws.
private func rounded(_ value: Binding<Double>, to step: Double) -> Binding<Double> {
    Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 / step).rounded() * step })
}

/// Nine buttons laid out like the screen; the lit one is where the plate sits.
private struct PlacementGrid: View {
    @Binding var selection: Int

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(Placement.grid.indices, id: \.self) { row in
                GridRow {
                    ForEach(Placement.grid[row], id: \.rawValue) { place in
                        Button {
                            selection = place.rawValue
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selection == place.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                                .frame(width: 26, height: 16)
                        }
                        .buttonStyle(.plain)
                        .help(place.title)
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.4)))
    }
}

private func described(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private extension View {
    @ViewBuilder
    func scrollEdgeEffectStyleSoftIfAvailable() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}
