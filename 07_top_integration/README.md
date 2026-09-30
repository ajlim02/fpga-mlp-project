# FPGA 전체 통합

`fpga_top`은 실제 `uart_packet_rx → mlp_top → uart_packet_tx → uart_tx`를 연결합니다.
`mlp_top` 내부의 feature buffer, controller, 3개 Dense layer, 공유 layer buffer와
SOH register를 그대로 사용합니다. 모의 MLP나 UART stub은 사용하지 않습니다.

## 파일 구성

- `rtl/fpga_top.sv`: 입력 보관, feature 순차 쓰기, 추론 시작, 결과 보관, 송신 완료 제어.
- `rtl/uart_packet_tx.sv`: 32비트 결과의 패킷화 및 기존 UART TX와의 핸드셰이크.
- `rtl/reset_sync.sv`: 비동기 리셋 인가 / 2클록 동기 해제.
- `rtl.f`: 저장소 루트 기준 실제 RTL 파일 목록.
- `tb/tb_fpga_top.sv`: UART 핀부터 실제 MLP 계산과 송신 핀까지 검증.
- `tb/generate_vectors.py`, `tb/mem/`: 독립 정수 기준 모델과 재현 가능한 검증 데이터.
- `tb/tb_uart_packet_tx.sv`: 결과 고정, 바이트 순서, busy 요청 무시, 리셋 검증.
- `run_tests.py`: 통합 및 UART 회귀 테스트 실행.

`06_uart/uart_rx`에는 기존에 `tb_uart_rx`가 들어 있어 수신 RTL이 없었습니다.
이 파일을 실제 UART 수신기로 복구했습니다. 확장자가 없는 UART 파일도
**SystemVerilog**로 컴파일해야 합니다.

## UART 프로토콜

8N1, 각 바이트의 bit 0부터 전송합니다. 기본값은 100 MHz / 115200 baud이며
양쪽 UART에 같은 정수 분주값 `CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE`를 적용합니다.
실제 FPGA 입력 클록에 맞춰 `CLK_FREQ_HZ`를 설정해야 합니다. 수신 지원 최소 분주값은 4입니다.

| 방향 | 프레임 | 바이트 순서 |
|---|---|---|
| PC → FPGA | `A5 F0 F1 F2 F3 F4 XOR` | signed int8 feature 0부터 |
| FPGA → PC | `5A R0 R1 R2 R3 XOR` | signed int32 결과, 하위 바이트부터 |

송신의 `5A` 헤더와 little-endian 규약은 이번 통합에서 정의했습니다.
XOR는 payload에만 적용하며 헤더는 포함하지 않습니다.
예: 입력 `[1,2,3,4,5]`는 `A5 01 02 03 04 05 01`입니다.
결과 `-70000`이면 `5A 90 EE FE FF 7F`입니다.
PC에서는 `int.from_bytes(payload, 'little', signed=True)`로 복원합니다.
현재 공통 형식에서 결과의 소수부는 8비트이므로 실수 변환은 raw / 256입니다.

## 상태와 흐름 제어

- 정상 요청을 수락한 뒤 입력 전체를 보관하고, 매 클록 feature 하나씩 내부 buffer에 씁니다.
- 마지막 feature 쓰기 다음 클록에서 추론을 시작합니다.
- `busy`는 요청 수락 이후 추론과 결과 송신 전체 동안 1입니다. 패킷을 수신 중인 상태는 포함하지 않습니다.
- `done`은 **체크섬의 마지막 stop bit가 끝난 뒤** 1클록 동안 1입니다.
- `error`는 수신 체크섬/stop-bit 오류를 리셋까지 기록합니다. 이후 정상 요청은 처리됩니다.
- 리셋은 진행 중 수신·추론·송신을 취소하며 TX 핀은 idle high로 복귀합니다.
- RX는 정상 패킷 하나를 추가로 유지할 수 있으나 무제한 FIFO나 RTS/CTS는 없습니다.
  **호스트는 응답을 모두 받은 뒤 다음 요청을 보내는 방식으로 사용하세요.**
  RX가 완성 패킷을 유지 중이면 추가 바이트는 무시됩니다.
- 기존 RX 패킷 파서에는 패킷 timeout이 없습니다. 중간에 요청 전송이 끊겼다면
  리셋 후 전체 패킷을 다시 보내야 합니다.

지원 구성은 int8 입력 1~16개, hidden 16/8, int32 출력 1개입니다.
기본 MLP는 5→16→8→1입니다. `OUTPUT_W=16`이나 복수 출력은 허용하지 않아
결과가 조용히 잘리는 문제를 방지합니다.

## 가중치와 메모리

Top의 `L1/2/3_WMEM_FILE`, `L1/2/3_BMEM_FILE`로 실제 학습된 `.mem` 파일을 지정합니다.
기본 파일명은 `wmem_l1.mem`, `bmem_l1.mem` 등입니다.
검증용 `tb/mem`은 **학습된 SOH 모델이 아닌 합성 테스트 데이터**입니다.

모든 레이어의 weight group stride는 `N_MAX=16`입니다.
8개 뉴런을 한 그룹으로 하며 weight는 64비트(8×8), bias는 256비트(8×32)입니다.
lane 0이 하위 비트입니다. L1 weight 깊이는 32, L2/L3는 각각 16입니다.
L3에서 사용하지 않는 입력 슬롯 8~15와 lane 1~7도 0으로 채웁니다.
개별 레이어 시험에서 사용하는 짧은 파일을 그대로 합치지 마세요.

## 테스트 실행

Python 3와 Verilator(타이밍 지원), C++20 컴파일러가 필요합니다.
저장소 루트에서 실행합니다.

```text
python 07_top_integration/run_tests.py
```

Windows에서 portable Verilator와 Zig C++를 사용하는 경우:

```text
python 07_top_integration/run_tests.py --verilator-root <verilator-directory> --zig <zig.exe>
```

`--only integration_16` 등으로 한 구성만 실행할 수 있습니다.
각 테스트의 컴파일/실행 로그는 `07_top_integration/build/<test>/`에 남습니다.
실패나 timeout은 0이 아닌 종료 코드로 보고합니다.
기존 하위 RTL의 비트폭 경고는 로그에 유지하며 오류와 assertion 실패는 허용하지 않습니다.

## Vivado에 추가할 소스

`rtl.f`에 있는 파일만 Design Sources로 추가하고 `fpga_top`을 top으로 지정합니다.
`01/02/03`의 연습용 동일 이름 모듈, testbench 및 예전 stub을 Design Sources에
함께 넣지 마세요. `04_dense_layer/rtl`의 버전이 현재 MLP core와 호환됩니다.
실제 가중치/편향 파일도 Memory Initialization Files로 추가합니다.

시뮬레이션은 `tb_fpga_top.sv`를 Simulation Sources에 추가하고, `tb/mem` 경로가
저장소 루트 기준으로 해석되도록 작업 디렉터리를 설정합니다.
이 변경에는 보드 핀 제약, 클록 생성 회로, 합성/배치배선 결과나 bitstream이 포함되지 않습니다.
