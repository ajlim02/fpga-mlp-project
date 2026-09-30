# 통합 검증 결과

기준 커밋: `e01bb71e6e57bbb381d58f22f291ec33b82ed522`

전체 64개 원본 파일의 구조와 RTL/테스트 인터페이스를 검토해,
실제 모듈로 컴파일 가능한 top integration 경로를 구성했습니다.

## 수정 원인

- 기존 top은 실제 `mlp_core`, `feature_buffer`에 없는 파라미터와 포트를 사용했습니다.
- `mlp_top`이 제어기, feature buffer, SOH register를 이미 포함하므로 이 모듈에 연결했습니다.
- 출력 폭을 공통 규약의 signed 32비트에 맞췄습니다.
- 누락된 `uart_packet_tx`를 구현했습니다.
- `06_uart/uart_rx` 안의 테스트벤치를 실제 수신 RTL로 교체했습니다.
- 서로 다른 버전의 동일 이름 모듈이 섞이지 않도록 명시적인 `rtl.f`를 추가했습니다.
- 오래된 stub을 제거하고 실제 UART 핀과 실제 MLP를 사용하는 테스트로 교체했습니다.

## 실행 결과

Verilator Windows 배포판(python package 5.48.0, 실행 로그의 엔진 버전 5.49)과
Zig 0.14.1 C++20으로 다음 6개 구성이 모두 통과했습니다.

| 구성 | 검증 결과 |
|---|---|
| integration_16 | 16 clocks/bit, 실제 UART/MLP 응답 29회 통과 |
| integration_4 | 4 clocks/bit, 실제 UART/MLP 응답 29회 통과 |
| packet_tx_1 | 1 clock/bit, 결과 고정·패킷·busy 요청 무시·리셋 통과 |
| packet_tx_16 | 16 clocks/bit, 같은 송신 검증 통과 |
| uart_rx | 기존 테스트: 정상 패킷 5개, 오류 2개 검출 통과; 868 clocks/bit |
| uart_tx | 기존 테스트: 256개 모든 byte를 포함한 265개 frame 통과 |

통합 테스트는 독립 Python 정수 모델이 계산한 24개 예상값을 사용합니다.
실제 weight/bias 파일 로딩, 두 hidden layer의 ReLU/재양자화, 음수 입력,
16비트 범위를 넘는 음수 결과, 바이트별 비트 유지 시간, XOR 체크섬,
오류 이후 복구, RX/계산/TX 중 리셋을 확인했습니다.
완료 펄스는 마지막 stop bit 이후에만 발생하며 추론 시작/완료 횟수도 검사합니다.

## 검증 범위

- 기본 5→16→8→1 구성의 RTL 시뮬레이션 결과입니다.
- 합성, 타이밍 분석, 보드 동작 및 실제 학습 모델의 SOH 정확도는 검증하지 않았습니다.
- 테스트 메모리는 재현 가능한 합성 데이터입니다. 실제 사용 시 학습된 메모리 파일을 지정해야 합니다.
- 기존 하위 Dense/MLP/packet RX의 비트폭 변환 경고는 남아 있습니다.
  변경한 top 및 새 UART RTL에는 해당 경고가 없으며, 전체 elaboration 오류는 없습니다.
- 연습용 개별 테스트에는 포트/모듈 이름 불일치, 메모리 reset 미연결,
  절대 출력 경로가 남아 있어 전체 저장소의 모든 테스트가 통과한다고 주장하지 않습니다.
  통합 빌드는 `rtl.f`를 기준으로 합니다.
- UART 프레임과 호스트 흐름 제어, 메모리 packing은 `README.md`에 설명되어 있습니다.

재실행: 저장소 루트에서 `python 07_top_integration/run_tests.py`.
