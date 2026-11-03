import SwiftUI
import UIKit

@main
struct SpotifyPiPApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { model.start() }
                .preferredColorScheme(.dark)
                .tint(Color(red: 29 / 255, green: 185 / 255, blue: 84 / 255))
        }
    }
}

/// PiP 화면 미리보기 (이 뷰가 그대로 PiP 창이 됩니다)
struct PiPPreview: UIViewRepresentable {
    let view: PiPDisplayView
    func makeUIView(context: Context) -> PiPDisplayView { view }
    func updateUIView(_ uiView: PiPDisplayView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var clientIdDraft = ""
    @State private var copied = false

    var body: some View {
        let s = model.settings
        let sp = model.spotify
        NavigationStack {
            Form {
                // ───────── 미리보기와 PiP ─────────
                Section {
                    PiPPreview(view: model.pip.view)
                        .aspectRatio(s.layout.size.width / s.layout.size.height, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

                    Button {
                        model.pip.toggle()
                    } label: {
                        Label(model.pip.active ? "PiP 창 닫기" : "PiP 창 띄우기",
                              systemImage: model.pip.active ? "pip.exit" : "pip.enter")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.bold)
                    }
                    .disabled(!model.pip.supported || (!model.pip.possible && !model.pip.active))

                    Toggle("앱을 나가면 자동으로 띄우기", isOn: Binding(get: { s.autoPiP }, set: { s.autoPiP = $0 }))
                } header: {
                    Text("PiP 창")
                } footer: {
                    if !model.pip.supported {
                        Text("이 기기에서는 PiP를 쓸 수 없습니다.")
                    } else if let e = model.pip.lastError {
                        Text(e).foregroundStyle(.red)
                    } else {
                        Text("PiP 창을 띄운 뒤 게임으로 넘어가면 창이 게임 위에 떠 있습니다. 창은 끌어서 옮기거나, 두 손가락으로 크기를 바꾸거나, 화면 가장자리로 밀어 숨길 수 있습니다. 창의 재생 버튼으로 Spotify를 일시 정지할 수도 있습니다.")
                    }
                }

                // ───────── 지금 재생 중 ─────────
                if sp.loggedIn {
                    Section("지금 재생 중") {
                        if let t = sp.track {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t.title).font(.headline)
                                Text(t.artist).font(.subheadline).foregroundStyle(.secondary)
                                Text(model.lyricsStatusText).font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("재생 중인 곡이 없습니다.").foregroundStyle(.secondary)
                        }
                        if let l = sp.limitText {
                            Text(l).font(.caption).foregroundStyle(.orange)
                        } else if let e = sp.lastError {
                            Text(e).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }

                // ───────── 계정 ─────────
                Section {
                    TextField("Client ID", text: $clientIdDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { s.clientId = clientIdDraft.trimmed }
                    if sp.loggedIn {
                        Button("로그아웃", role: .destructive) { sp.logout() }
                    } else {
                        Button("Spotify 로그인") {
                            s.clientId = clientIdDraft.trimmed
                            sp.login(clientId: s.clientId)
                        }
                        .fontWeight(.bold)
                    }
                    HStack {
                        Text("Redirect URI").foregroundStyle(.secondary)
                        Spacer()
                        Text(SpotifyService.redirectURI).font(.system(.footnote, design: .monospaced))
                        Button(copied ? "복사 완료" : "복사") {
                            UIPasteboard.general.string = SpotifyService.redirectURI
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("Spotify 계정 연결")
                } footer: {
                    Text("\(sp.message) Spotify 개발자 대시보드의 앱 설정에서 Redirect URIs에 위 주소를 추가해야 로그인할 수 있습니다. PC 오버레이에서 쓰는 Client ID를 그대로 써도 됩니다.")
                }

                // ───────── 화면 구성 ─────────
                Section("화면 구성") {
                    Picker("표시 내용", selection: Binding(get: { s.layout }, set: { s.layout = $0 })) {
                        ForEach(PiPLayout.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                // ───────── 테마 ─────────
                Section("추천 색 테마") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Themes.all) { th in
                                ThemeChip(theme: th, selected: th.id == s.themeId)
                                    .onTapGesture { s.themeId = th.id }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // ───────── 가사 ─────────
                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("가사 싱크")
                            Spacer()
                            Text("\(s.offsetMs > 0 ? "+" : "")\(Int(s.offsetMs))ms")
                                .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { s.offsetMs }, set: { s.offsetMs = $0 }), in: -3000...3000, step: 50)
                    }
                    Toggle("Musixmatch (Spotify 가사)", isOn: s.binding(for: "musixmatch"))
                    Toggle("LRCLIB (해외 곡)", isOn: s.binding(for: "lrclib"))
                    Toggle("알송 (한국 곡)", isOn: s.binding(for: "alsong"))
                    Toggle("NetEase (K-pop)", isOn: s.binding(for: "netease"))
                    Button("지금 곡 가사 다시 찾기") { model.lyrics.refresh() }
                } header: {
                    Text("가사")
                } footer: {
                    Text("가사가 노래보다 늦게 나오면 + 쪽으로, 빨리 나오면 - 쪽으로 옮겨 주세요. 켜 둔 곳에서 한 번에 찾고, 여러 곳에 가사가 있으면 Musixmatch, LRCLIB, 알송, NetEase 순서로 먼저인 곳의 가사를 씁니다.")
                }
            }
            .navigationTitle("가사 PiP")
            .onAppear { clientIdDraft = s.clientId }
        }
    }
}

struct ThemeChip: View {
    let theme: Theme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(theme.bar.color).frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("곡 제목").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.title.color)
                        Text("가수").font(.system(size: 8)).foregroundStyle(theme.artist.color)
                    }
                }
                Text("지금 가사")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(theme.current.color)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.box.color))
                    .frame(maxWidth: .infinity)
            }
            .padding(7)
            .frame(width: 104)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.bg.color))
            Text(theme.name).font(.caption.bold()).foregroundStyle(.primary)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 11).stroke(selected ? Color.green : Color.gray.opacity(0.3), lineWidth: selected ? 2 : 1))
    }
}
