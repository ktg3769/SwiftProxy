# SwiftProxy

iPhone에서 SOCKS5 / HTTP 프록시 서버를 실행하는 개인용 iOS 앱 (iOS 26 이상).

> 개인용으로 개발 중입니다. 실기기 검증 전이므로 아래 기능은 CI(시뮬레이터) 테스트 기준입니다.

## 기능

- SOCKS5 CONNECT (IPv4 / IPv6 / 도메인), 사용자 이름·비밀번호 인증 (RFC 1929)
- HTTP 포워드 프록시, HTTP CONNECT 터널, Basic 프록시 인증
- PAC 파일: `http://<iPhone IP>:<HTTP 포트>/proxy.pac` (또는 `/wpad.dat`)
- 연결별 통계, 연결 강제 종료, 유휴(5분)·핸드셰이크(15초) 시간 초과
- 외부 연결 경로 선택: 시스템 기본 / 셀룰러만
- iOS 26 BGContinuedProcessingTask로 백그라운드 실행 (앱 쪽 시간 제한 없음, 시스템이 종료할 수 있음)
- 잠금 화면·다이나믹 아일랜드 Live Activity

백그라운드 실행의 한계는 [docs/LIMITATIONS.md](docs/LIMITATIONS.md)를 꼭 읽어 주세요.

## 빌드

로컬 Xcode 없이 GitHub Actions(`macos-26` runner)에서 빌드합니다.

1. `main`에 푸시하면 `.github/workflows/build.yml`이 실행됩니다.
2. XcodeGen으로 `project.yml` → `SwiftProxy.xcodeproj` 생성
3. 시뮬레이터에서 단위 테스트 실행
4. Release archive (서명 없음) → `Payload/SwiftProxy.app` 구조의 **unsigned IPA** 생성
5. `scripts/verify_ipa.sh`가 IPA 구조·Bundle ID·실행 파일을 검사
6. Actions 실행 페이지의 Artifacts에서 `SwiftProxy-unsigned-ipa` 다운로드

## 설치 (ESign)

Actions가 만드는 IPA는 **서명되지 않은** 상태라 그대로는 설치되지 않습니다.
ESign에서 본인 인증서로 서명한 뒤 설치하세요. 인증서·개인 키·프로비저닝 프로파일은
이 저장소에 절대 커밋하지 않습니다 (`.gitignore`로 차단).

## 구조

```
project.yml                 XcodeGen 프로젝트 정의
SwiftProxy/App              앱 진입점, AppState
SwiftProxy/Features         Dashboard / Connections / Diagnostics / Settings 화면
SwiftProxy/Proxy            리스너·연결 관리 (ProxyServerManager)
SwiftProxy/Network          NWPathMonitor, 인터페이스 주소
SwiftProxy/Services         설정 저장, Keychain, 접근 제어, 통계, 로그
SwiftProxy/Models           설정·상태 모델
SwiftProxy/Background       BGContinuedProcessingTask, 세션 기록
SwiftProxy/LiveActivity     Live Activity 시작·갱신·종료
SwiftProxyLiveActivity      위젯 확장 (잠금 화면, 다이나믹 아일랜드)
Shared                      앱과 위젯이 함께 쓰는 코드
SwiftProxyTests             단위 테스트
scripts/verify_ipa.sh       IPA 구조 검증
```

## 보안 기본값

- 접근 정책 기본값: **로컬 네트워크만** (사설 IP 대역만 허용)
- 셀룰러 인터페이스로 들어오는 연결은 받지 않음
- 인증은 기본 꺼짐. 켜면 무작위 비밀번호를 생성해 Keychain에 저장 (고정 기본 비밀번호 없음)
- 로그의 클라이언트 IP는 디버그 수준이 아니면 일부 마스킹

## 알려진 제한

[docs/LIMITATIONS.md](docs/LIMITATIONS.md) 참고. 요약:
- 백그라운드 실행은 BGContinuedProcessingTask에 의존하며, 사용자 취소·자원 부족·앱 스위처 종료 시 멈춥니다.
- Live Activity는 표시일 뿐 서버를 살려 두지 않습니다 (갱신이 끊기면 "확인 불가"로 표시).
- SOCKS5 BIND/UDP, SOCKS4, HTTP keep-alive 재사용은 지원하지 않습니다.
