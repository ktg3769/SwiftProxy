# SwiftProxy

iPhone에서 SOCKS5 / HTTP 프록시 서버를 실행하는 개인용 iOS 앱 (iOS 26 이상).

> 개발 중입니다. 현재 Phase 2: UI·상태·설정·리스너 골격까지 구현되어 있고,
> **SOCKS5/HTTP 프로토콜 처리는 아직 없습니다** (들어온 연결은 즉시 닫힙니다).

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
SwiftProxyTests             단위 테스트
scripts/verify_ipa.sh       IPA 구조 검증
```

## 보안 기본값

- 접근 정책 기본값: **로컬 네트워크만** (사설 IP 대역만 허용)
- 셀룰러 인터페이스로 들어오는 연결은 받지 않음
- 인증은 기본 꺼짐. 켜면 무작위 비밀번호를 생성해 Keychain에 저장 (고정 기본 비밀번호 없음)
- 로그의 클라이언트 IP는 디버그 수준이 아니면 일부 마스킹

## 알려진 제한

백그라운드 실행 제한과 BGContinuedProcessingTask 동작은 Phase 4에서 정리합니다.
현재 버전은 앱이 백그라운드로 가면 iOS가 프로세스를 일시 중지하므로 서버도 멈춥니다.
