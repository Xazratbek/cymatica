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
        case .general: tr("Umumiy", "Основные", "General")
        case .appearance: tr("Ko'rinish", "Внешний вид", "Appearance")
        case .about: tr("Haqida", "О программе", "About")
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
    static var displayString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(tr("Versiya", "Версия", "Version")) \(version) (\(build))"
    }
}

// MARK: - Root

struct SettingsView: View {
    let actions: SettingsActions
    @AppStorage("language") private var language = Language.uz.rawValue
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
            .navigationTitle(tr("Sozlamalar", "Настройки", "Settings"))
            .frame(width: 200)
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(for: navigation.selectedTab ?? .general)
        }
        .navigationTitle(tr("Sozlamalar", "Настройки", "Settings"))
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 660, minHeight: 540)
        // Rebuild every label when the interface language changes.
        .id(language)
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
    @AppStorage("language") private var language = Language.uz.rawValue
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
            Section(tr("Til", "Язык", "Language")) {
                Picker(tr("Ilova tili", "Язык приложения", "App language"), selection: $language) {
                    ForEach(Language.allCases, id: \.rawValue) { language in
                        Text(language.nativeName).tag(language.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(tr("Rejim", "Режим", "Mode")) {
                Picker(tr("Qum nimani chizadi", "Что рисует песок", "Sand draws"), selection: $mode) {
                    ForEach(DisplayMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(modeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(isOn: $followRhythm) {
                    described(tr("Musiqa ritmiga moslashsin", "Следовать ритму музыки", "Follow the rhythm"),
                              tr("Har zarbda chiziqlar orasidagi qum sakraydi va naqsh yorishadi, har taktda naqsh almashadi. Kamera tezligi musiqaning kuchiga qarab o'zgaradi.",
                                 "На каждый удар песок между линиями подпрыгивает и фигура вспыхивает, на каждый такт фигура меняется. Скорость камеры зависит от силы музыки.",
                                 "On every beat the loose sand leaps and the figure flares; the figure changes every bar. The camera speeds up with the music."))
                }
                .toggleStyle(.switch)
            }

            Section(tr("Avtomatik yoqilish", "Автоматическое включение", "Turning on")) {
                Toggle(isOn: $autoMode) {
                    described(tr("Avtomatik yoqilsin", "Включаться автоматически", "Turn on automatically"),
                              tr("Mac tegilmay turganda plastinka sekin paydo bo'ladi.",
                                 "Когда Mac не трогают, пластина плавно появляется.",
                                 "When the Mac is left alone, the plate fades in."))
                }
                .toggleStyle(.switch)
                LabeledContent(tr("Kutish vaqti", "Ожидание", "Wait")) {
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
                    described(tr("Musiqa bo'lmasa ham yoqilsin", "Включаться и без музыки", "Also without music"),
                              tr("Telefondagi always on display kabi: soat doim ko'rinadi. Ekran uyg'oq turadi, batareya ko'proq sarflanadi.",
                                 "Как always-on display на телефоне: часы видны всегда. Экран не гаснет, батарея расходуется быстрее.",
                                 "Like a phone's always-on display: the clock stays visible. The screen stays awake and uses more battery."))
                }
                .toggleStyle(.switch)
                .disabled(!autoMode)
                Toggle(isOn: $respectVideo) {
                    described(tr("Video ko'rilayotganda yoqilmasin", "Не включаться во время видео", "Stay hidden during video"),
                              tr("Boshqa ilova ekranni uyg'oq ushlab tursa (odatda video), plastinka chiqmaydi.",
                                 "Если другое приложение не даёт экрану погаснуть (обычно видео), пластина не появляется.",
                                 "If another app keeps the screen awake (usually a video), the plate does not appear."))
                }
                .toggleStyle(.switch)
                .disabled(!autoMode)
            }

            Section(tr("O'chirish", "Выключение", "Closing")) {
                Toggle(isOn: Binding(get: { !keyboardDismisses }, set: { keyboardDismisses = !$0 })) {
                    described(tr("Klaviatura bosilganda o'chmasin", "Не закрывать от клавиатуры", "Keys do not close it"),
                              tr("Plastinka faqat trackpad yoki sichqoncha tegilganda yopiladi.",
                                 "Пластина закрывается только от трекпада или мыши.",
                                 "Only the trackpad or mouse closes the plate."))
                }
                .toggleStyle(.switch)
            }

            Section(tr("Ovoz", "Звук", "Audio")) {
                LabeledContent(tr("Manba", "Источник", "Source")) {
                    Text(actions.audioStatus())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                Button(tr("Maxfiylik sozlamalarini ochish", "Открыть настройки конфиденциальности", "Open Privacy settings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }
                .controlSize(.small)
            }

            Section(tr("Tizim", "Система", "System")) {
                Toggle(isOn: loginBinding) {
                    described(tr("Mac yoqilganda ishga tushsin", "Запускать при входе", "Launch at login"),
                              tr("Menyu satrida o'zi paydo bo'ladi.",
                                 "Значок сам появится в строке меню.",
                                 "The icon appears in the menu bar by itself."))
                }
                .toggleStyle(.switch)
                if loginStatus == .requiresApproval {
                    LabeledContent(tr("macOS tasdig'ini kutmoqda", "Ждёт подтверждения macOS", "Waiting for macOS approval")) {
                        Button(tr("Login Items'ni ochish", "Открыть «Объекты входа»", "Open Login Items")) {
                            SMAppService.openSystemSettingsLoginItems()
                        }
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
        case .music:
            tr("Qum musiqaning notasiga qarab Xladni naqshlarini chizadi.",
               "Песок рисует фигуры Хладни по ноте, на которой построена музыка.",
               "The sand draws Chladni figures from the note the music is built on.")
        case .clock:
            tr("Qum hozirgi vaqtni chizadi. Soniya almashsa, faqat o'sha raqamning qumi sakraydi.",
               "Песок рисует текущее время. Когда меняется секунда, подпрыгивает только песок этой цифры.",
               "The sand draws the current time. When a second ticks, only that digit's sand jumps.")
        case .mixed:
            tr("Musiqa chalinsa Xladni naqshlari, musiqa to'xtasa qum soatga aylanadi.",
               "Пока играет музыка — фигуры Хладни, когда она стихает — песок собирается в часы.",
               "Chladni figures while music plays; when it stops, the sand turns into a clock.")
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let s = tr("s", "с", "s"), min = tr("daq", "мин", "min")
        return total < 60 ? "\(total) \(s)" : total % 60 == 0 ? "\(total / 60) \(min)" : "\(total / 60) \(min) \(total % 60) \(s)"
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
            Section(tr("Soat", "Часы", "Clock")) {
                Picker(tr("Ko'rinishi", "Стиль", "Style"), selection: $clockStyle) {
                    Text(tr("Raqamli", "Цифровые", "Digital")).tag(ClockStyle.digital.rawValue)
                    Text(tr("Doira", "Циферблат", "Analog")).tag(ClockStyle.analog.rawValue)
                    Text(tr("Halqalar", "Кольца", "Rings")).tag(ClockStyle.rings.rawValue)
                }
                .pickerStyle(.segmented)
                Toggle(tr("Soniyalarni ko'rsatish", "Показывать секунды", "Show seconds"), isOn: $showSeconds)
                    .toggleStyle(.switch)
            }

            Section(tr("Plastinka", "Пластина", "Plate")) {
                Picker(tr("Shakl", "Форма", "Shape"), selection: $shape) {
                    Text(tr("Kvadrat", "Квадрат", "Square")).tag(PlateField.Shape.square.rawValue)
                    Text(tr("Doira", "Круг", "Circle")).tag(PlateField.Shape.circle.rawValue)
                }
                .pickerStyle(.segmented)
                LabeledContent(tr("Qum miqdori", "Количество песка", "Amount of sand")) {
                    HStack(spacing: 12) {
                        Slider(value: rounded($grainDraft, to: 10_000), in: 20_000...300_000) { editing in
                            if !editing { grainCount = Int(grainDraft) }
                        }
                        .frame(width: 180)
                        Text(tr("\(Int(grainDraft) / 1000) ming", "\(Int(grainDraft) / 1000) тыс.", "\(Int(grainDraft) / 1000)k"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
                Toggle(isOn: $showCaption) {
                    described(tr("Nota va chastotani ko'rsatish", "Показывать ноту и частоту", "Show note and frequency"),
                              tr("Naqsh almashganda pastda bir necha soniya xira yozuv chiqadi.",
                                 "При смене фигуры внизу на несколько секунд появляется тусклая подпись.",
                                 "A dim caption appears at the bottom for a few seconds when the figure changes."))
                }
                .toggleStyle(.switch)
            }

            Section(tr("Joylashuv", "Расположение", "Placement")) {
                LabeledContent(tr("Ekrandagi joyi", "Место на экране", "Position")) {
                    PlacementGrid(selection: $placement)
                }
                LabeledContent(tr("O'lchami", "Размер", "Size")) {
                    HStack(spacing: 12) {
                        Slider(value: rounded($plateSize, to: 0.05), in: 0.4...1.2)
                            .frame(width: 180)
                        Text("\(Int((plateSize * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
                Picker(tr("Qaysi ekranda", "Экран", "Display"), selection: $screenID) {
                    Text(tr("Avtomatik (Mac ekrani)", "Авто (экран Mac)", "Automatic (built-in)")).tag(0)
                    ForEach(NSScreen.screens, id: \.displayID) { screen in
                        Text(screen.localizedName).tag(Int(screen.displayID))
                    }
                }
                .pickerStyle(.radioGroup)
                Picker(tr("Kadr tezligi", "Частота кадров", "Frame rate"), selection: $framesPerSecond) {
                    Text("60 FPS").tag(60)
                    Text("120 FPS").tag(120)
                }
                .pickerStyle(.segmented)
            }

            Section {
                HStack(spacing: 8) {
                    Button(tr("Hozir ko'rish", "Показать сейчас", "Show now"), action: actions.showNow)
                        .controlSize(.small)
                    Button(tr("Qumni qayta sepish", "Рассыпать песок заново", "Re-sprinkle the sand"), action: actions.rescatter)
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
            Section(tr("Bu nima", "Что это", "What it is")) {
                Text(tr("Qora tebranuvchi plastinkadagi oltin qum. Qo'shiqning asosiy notasi plastinkaning tebranish shaklini tanlaydi, qum esa qimirlamaydigan chiziqlarga yig'iladi. Akkord almashsa, qum sakrab yangi naqsh hosil qiladi.",
                        "Золотой песок на чёрной вибрирующей пластине. Основная нота песни выбирает форму колебаний пластины, а песок собирается на неподвижных линиях. Когда меняется аккорд, песок подпрыгивает и складывается в новую фигуру.",
                        "Golden sand on a black vibrating plate. The song's main note picks how the plate vibrates, and the sand gathers on the lines that stay still. When the chord changes, the sand jumps and forms a new figure."))
                Text(tr("1787-yilda Ernst Xladni skripka kamoni bilan qum sepilgan plastinkada xuddi shu naqshlarni ko'rsatgan. Bu bezak emas, shu fizikaning simulyatsiyasi.",
                        "В 1787 году Эрнст Хладни показал те же узоры, проводя смычком скрипки по посыпанной песком пластине. Это не украшение, а симуляция той же физики.",
                        "In 1787 Ernst Chladni showed these same patterns by bowing a sand-covered plate with a violin bow. This is not decoration but a simulation of that physics."))
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
