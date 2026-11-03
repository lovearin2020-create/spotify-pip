# 가사 PiP (Spotify PiP)

아이폰과 아이패드에서 게임 위에 Spotify 지금 재생 중인 곡과 가사를 띄워 주는 앱입니다.
iOS의 화면 속 화면(PiP) 창에 곡 정보와 가사 세 줄을 그려 넣습니다.

- 곡 정보: 앨범 아이콘, 제목, 가수, 재생 바와 시간
- 가사: 이전 줄 / 현재 줄(크게, 박스) / 다음 줄, 줄이 바뀔 때 굴러가는 애니메이션
- 가사 검색처: Musixmatch, LRCLIB, 알송, NetEase (켜고 끌 수 있음)
- PiP 창의 재생 버튼으로 Spotify 재생과 일시 정지
- 추천 색 테마 9가지, 화면 구성 3가지 (곡 정보 + 가사, 가사만, 곡 정보만)

## 설치 (Sideloadly)

1. 이 저장소의 `ci` 브랜치에서 `SpotifyPiP.ipa`를 받습니다.
2. Sideloadly에 ipa를 끌어다 놓고, Apple ID를 넣고 Start를 누릅니다.
3. 아이폰 설정 > 일반 > VPN 및 기기 관리에서 개발자 앱을 신뢰합니다.
4. 무료 Apple ID로 설치하면 7일마다 다시 설치해야 합니다.

## Spotify 설정

Spotify 개발자 대시보드의 앱 설정에서 Redirect URIs에 `spotifypip://callback`을 추가합니다.
PC 오버레이에서 쓰는 Client ID를 그대로 써도 됩니다.

## 빌드

`main`에 올리면 GitHub Actions(macOS)가 XcodeGen으로 프로젝트를 만들고 서명 없는 ipa를 빌드해서 `ci` 브랜치에 올립니다.
