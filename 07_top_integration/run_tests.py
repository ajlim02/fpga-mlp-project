"""Run real RTL tests. Requires Verilator and a C++20 compiler.

Normal: python 07_top_integration/run_tests.py
Windows alternative: --verilator-root PATH --zig PATH_TO_ZIG_EXE
The optional paths use a portable Verilator distribution and Zig C++ compiler.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
HERE = Path(__file__).resolve().parent

def run(command, log, env):
    result = subprocess.run([str(x) for x in command], cwd=ROOT, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            encoding='utf-8', errors='replace', timeout=600)
    log.write_text(result.stdout, encoding='utf-8')
    if result.returncode:
        print(result.stdout)
        raise RuntimeError(f'Command failed ({result.returncode}); see {log}')
    return result.stdout

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verilator-root', type=Path)
    parser.add_argument('--zig', type=Path)
    parser.add_argument('--only', help='Run just one named test')
    args = parser.parse_args()
    env = os.environ.copy()
    verilator = 'verilator'
    if args.verilator_root:
        args.verilator_root = args.verilator_root.resolve()
        env['VERILATOR_ROOT'] = str(args.verilator_root)
        verilator = args.verilator_root / 'bin' / 'verilator_bin.exe'
    if args.zig and not args.verilator_root:
        parser.error('--zig requires --verilator-root')
    build = HERE / 'build'
    build.mkdir(exist_ok=True)
    env.setdefault('ZIG_GLOBAL_CACHE_DIR', str(build / 'zig-cache'))
    subprocess.run([sys.executable, str(HERE / 'tb/generate_vectors.py')], check=True)
    rtl = (HERE / 'rtl.f').read_text().splitlines()
    tests = [
        ('integration_16', 'tb_fpga_top', rtl + ['07_top_integration/tb/tb_fpga_top.sv'], ['-GCPB=16']),
        ('integration_4', 'tb_fpga_top', rtl + ['07_top_integration/tb/tb_fpga_top.sv'], ['-GCPB=4']),
        ('packet_tx_1', 'tb_uart_packet_tx', ['06_uart/uart_tx', '07_top_integration/rtl/uart_packet_tx.sv', '07_top_integration/tb/tb_uart_packet_tx.sv'], ['-GCPB=1']),
        ('packet_tx_16', 'tb_uart_packet_tx', ['06_uart/uart_tx', '07_top_integration/rtl/uart_packet_tx.sv', '07_top_integration/tb/tb_uart_packet_tx.sv'], ['-GCPB=16']),
        ('uart_rx', 'tb_uart_rx', ['06_uart/uart_rx', '06_uart/uart_packet_rx', '06_uart/tb_uart_rx'], []),
        ('uart_tx', 'tb_uart_tx', ['06_uart/uart_tx', '06_uart/tb_uart_tx'], []),
    ]
    if args.only:
        tests = [t for t in tests if t[0] == args.only]
        if not tests:
            parser.error('Unknown test name')
    for name, top, sources, params in tests:
        target = build / name
        target.mkdir(exist_ok=True)
        common = [verilator, '--timing', '--assert', '-Wno-fatal', '--top-module', top,
                  '--Mdir', target, *params, *sources]
        if args.zig:
            run(common + ['--cc', '--main'], target / 'elaborate.log', env)
            inc = args.verilator_root / 'include'
            exe = target / 'sim.exe'
            run([args.zig.resolve(), 'c++', '-std=c++20', '-O0', '-DVL_TIME_CONTEXT', f'-I{target}', f'-I{inc}',
                 f'-I{inc / "vltstd"}', *target.glob('*.cpp'), inc / 'verilated.cpp',
                 inc / 'verilated_timing.cpp', inc / 'verilated_threads.cpp', '-o', exe],
                target / 'compile.log', env)
        else:
            run(common + ['--binary', '-j', '2'], target / 'compile.log', env)
            exe = target / ('V' + top + ('.exe' if os.name == 'nt' else ''))
        output = run([exe], target / 'run.log', env)
        if 'PASS:' not in output or 'FAIL' in output:
            raise RuntimeError(f'No clean PASS marker: {target / "run.log"}')
        print(name + ': ' + next(line for line in output.splitlines() if 'PASS:' in line))
    print(f'PASS: {len(tests)} test configurations')

if __name__ == '__main__':
    main()
