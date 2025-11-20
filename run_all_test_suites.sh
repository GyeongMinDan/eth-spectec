#!/bin/bash

# sanity, finality, random 테스트 스위트를 순차적으로 실행하는 스크립트

set -e  # 에러 발생 시 스크립트 중단

# 스크립트가 있는 디렉터리로 이동
cd "$(dirname "$0")"

echo "=========================================="
echo "테스트 스위트 실행 시작"
echo "=========================================="
echo ""

# 1. Sanity 테스트
echo "=========================================="
echo "[1/3] Sanity 테스트 실행 중..."
echo "=========================================="
python3 Converter/run_test_suite.py \
  Converter/OfficialTestSuite/sanity/blocks/pyspec_tests \
  --spectec-bin ./spectec-core \
  --run-mode run-sl \
  -v

echo ""
echo "✅ Sanity 테스트 완료"
echo ""

# 2. Finality 테스트
echo "=========================================="
echo "[2/3] Finality 테스트 실행 중..."
echo "=========================================="
python3 Converter/run_test_suite.py \
  Converter/OfficialTestSuite/finality/pyspec_tests \
  --spectec-bin ./spectec-core \
  --run-mode run-sl \
  -v

echo ""
echo "✅ Finality 테스트 완료"
echo ""

# 3. Random 테스트
echo "=========================================="
echo "[3/3] Random 테스트 실행 중..."
echo "=========================================="
python3 Converter/run_test_suite.py \
  Converter/OfficialTestSuite/random/random/pyspec_tests \
  --spectec-bin ./spectec-core \
  --run-mode run-sl \
  -v

echo ""
echo "✅ Random 테스트 완료"
echo ""

echo "=========================================="
echo "모든 테스트 스위트 실행 완료!"
echo "=========================================="

