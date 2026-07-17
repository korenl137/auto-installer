# Windows 자동 설치 도구 (v0.1.0)

본 스크립트는 윈도우 환경 구축 시 필요한 대량의 소프트웨어를 TUI(Text User Interface) 상에서 인터랙티브하게 선택하여 한 번에 무음(Silent) 설치할 수 있도록 돕는 PowerShell 자동화 도구입니다.

## 주요 특징 (Key Features)

1. **키보드 기반의 TUI 선택 화면**: 마우스 없이 방향키(`↑`/`↓`), 좌우 방향키(`←`/`→`, 섹션 간 이동), `Space`키(선택/해제), `A`키(전체선택), `N`키(전체해제), `Enter`키(시작)를 활용해 설치할 앱 목록을 손쉽게 커스텀할 수 있습니다.
2. **이미 설치된 프로그램의 런타임 스킵**: 실행 직후 시스템에 기설치된 소프트웨어(Winget/Store ID 기준 및 포터블)를 탐색하여 TUI 상에서 녹색(`DarkGreen`)으로 다르게 표기하고 기본 체크를 해제합니다. 실행 중에도 중복 설치 시도를 원천 차단(Skip)하여 리소스를 아낍니다.
3. **설치 진행 중 양방향 제어 (Granular Interrupt)**: 패키지 설치 프로세스가 백그라운드에서 동작할 때 `Q` 또는 `Esc` 키를 입력하여 다음 액션을 직관적으로 지시할 수 있습니다:
   - **1. 해당 항목 중지**: 현재 진행 중인 인스톨러 프로세스를 즉시 강제 종료(`Kill`)하고 실패 처리 후 다음 앱으로 넘어갑니다.
   - **2. 전체 설치 중지**: 현재 프로세스를 종료하고 남은 모든 앱들의 설치를 건너뛴 채 결과 보고서 화면으로 이행합니다.
   - **3. 계속 진행**: TUI 화면의 경고창을 흔적 없이 지우고 커서를 원복하여 설치 완료를 마저 기다립니다.
4. **시간별 개별 로그 파일 분리**: 실행 시각이 포함된 고유한 텍스트 파일(`logs/auto-install-log-yyyyMMdd_HHmmss.txt`)이 매번 새로 생성되어 이전 디버그/오류 기록을 보존하고 문제점을 추적하기 용이합니다.
5. **안전 장치 탑재**: 비관리자 실행 시 UAC 권한 승격을 요구하며, 환경 변수(PATH) 실시간 갱신을 통해 Git, Python 등 설치 즉시 세션에서 연동되도록 지원합니다.

---

## 설치 및 사용 방법 (How to Use)

### 1. 사전 권한 설정
PowerShell 스크립트 실행을 위해 관리자 권한으로 실행된 터미널에서 다음 명령어를 실행하여 실행 정책(ExecutionPolicy)을 허용해 주십시오:
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
```

### 2. 스크립트 실행
터미널에서 개선된 스크립트 파일을 실행합니다:
```powershell
.\auto-installer.ps1
```

> **필수 동반 파일 (v0.1.0부터)**: `auto-installer.ps1`은 같은 폴더에 있는 `AutoInstaller.Core.ps1`(핵심 로직 모듈)과 `catalog.json`(앱 카탈로그 데이터)을 자동으로 불러옵니다. 두 파일 중 하나라도 없으면 실행 시 오류 메시지와 함께 종료됩니다. 배포/복사 시 세 파일(`auto-installer.ps1`, `AutoInstaller.Core.ps1`, `catalog.json`)을 항상 같은 폴더에 함께 두어야 합니다.

### 3. TUI 조작법
- `↑ / ↓` : 앱 카탈로그 목록 내에서 항목 이동
- `← / →` : 이전 / 다음 섹션(카테고리) 헤더로 점프
- `Space` : 항목 체크 / 해제
- `A` : 모든 항목 일괄 선택
- `N` : 모든 항목 일괄 해제
- `Enter` : 선택된 패키지들의 무음 설치 루프 실행
- `Esc` : 선택 화면에서는 프로그램 종료 / 설치 확인창에서는 선택 화면으로 복귀

---

## 기술 정보 및 트러블슈팅

### 1. 키보드 입력 반응성 향상 (StandardInput 리다이렉션)
자식 인스톨러가 부모 셸의 콘솔 키보드 입력을 임의로 점유하거나 방해하는 현상을 해결하기 위해, 모든 프로세스는 표준 입력을 `$env:TEMP\empty-stdin.txt`로 우회 공급받습니다. 이 조치를 통해 `Q`/`Esc` 키 이벤트가 부모 셸의 버퍼에 100% 안정적으로 누적되어 지연 없이 프롬프트를 띄울 수 있습니다.

### 2. 인코딩 권장 사항
본 스크립트는 한글 TUI 및 유니코드 문자를 출력합니다. Windows PowerShell 5.1 호환성을 위해 파일은 반드시 **UTF-8 with BOM** 인코딩 상태를 유지해야 주석이나 TUI의 한글이 깨지지 않고 구문 컴파일 오류를 예방할 수 있습니다. `catalog.json`은 일반 UTF-8(BOM 없음)로 저장되어 있으며, `Get-Content -Encoding UTF8`로 읽으므로 별도 조치가 필요 없습니다.

### 3. 앱 카탈로그 수정 방법 (v0.1.0부터)
설치 가능한 앱 목록은 더 이상 스크립트 안에 하드코딩되어 있지 않고 `catalog.json`에 분리되어 있습니다. 앱을 추가/삭제/수정하려면 스크립트를 건드릴 필요 없이 `catalog.json`의 `winget` / `store` / `github` / `manual` 배열과 `customMappings` 객체만 편집하면 됩니다. 배열 내 항목의 순서가 TUI 메뉴에 표시되는 순서와 동일하므로 순서에 유의해 주십시오.

> **주의**: `customMappings`에 넣는 대체 이름 값은 실제 `winget list` 출력이나 프로그램 표시 이름과 정확히 일치해야 합니다. 예를 들어 한국어 Windows에서 카카오톡은 "카카오톡"으로, 한컴오피스는 "한컴오피스"로 표시되므로 이 한글 문자열이 반드시 값으로 포함되어야 합니다. (과거 영문 번역 작업 중 이 한글 리터럴이 실수로 영문으로 치환되어 설치 감지가 깨진 적이 있었습니다 — v0.1.0에서 복구됨. CHANGELOG 참고.)

### 4. 단위 테스트 (Pester)
설치 감지 로직(`Test-IsAppInstalled`)과 CJK 문자폭 계산 로직(`Get-VisualWidth`/`Get-VisualPadRight`/`Get-VisualSubstring`) 등 핵심 로직은 `AutoInstaller.Core.ps1`로 분리되어 있으며, `tests/Core.Tests.ps1`로 [Pester](https://pester.dev/) 단위 테스트를 실행할 수 있습니다.
```powershell
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0   # 최초 1회
Invoke-Pester -Path .\tests\Core.Tests.ps1 -Output Detailed
```

### 5. 폴백 매칭 오탐 확인 (WARN 로그)
`Test-IsAppInstalled`의 2~5단계 휴리스틱 폴백 매칭이 발동해 "이미 설치됨"으로 판정될 때마다 로그 파일에 `WARN` 레벨로 판정 근거가 기록됩니다. 실행 후 `logs/auto-install-log-*.txt`에서 `[ WARN ]` 항목을 확인하면, 실제로는 다른 앱인데 잘못 "설치됨"으로 처리된 사례가 없는지 점검할 수 있습니다.

> **개발 안내 (Development Notice)**: 본 프로그램은 AI 코딩 어시스턴트의 도움을 받아 개발되었습니다.