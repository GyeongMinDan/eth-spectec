#!/bin/bash

# sanity, finality, random 테스트 스위트를 sequential 모드로 순차적으로 실행하는 스크립트
# Deneb과 Capella 모두 실행

set -e  # 에러 발생 시 스크립트 중단

# 스크립트가 있는 디렉터리로 이동
cd "$(dirname "$0")"

# 전체 시작 시간 기록
TOTAL_START_TIME=$(date +%s)

# 테스트 실행 함수 정의
run_test_suite() {
    local TEST_SUITE_PATH="$1"
    local WORKFLOW_MODE="$2"  # sequential or independent
    local OUTPUT_SUFFIX="$3"  # _sanity_sequential, _finality_sequential, etc.
    
    # Extract fork name from path (capella or deneb)
    local FORK_NAME=$(echo "$TEST_SUITE_PATH" | sed -n 's|.*OfficialTestSuite/\([^/]*\)/.*|\1|p')
    
    # Determine output directory based on test suite type
    local OUTPUT_DIR
    if [[ "$TEST_SUITE_PATH" == *"/sanity/"* ]]; then
        # Sanity: remove /blocks/pyspec_tests
        OUTPUT_DIR="${TEST_SUITE_PATH%/*/*}/${OUTPUT_SUFFIX}"
    elif [[ "$TEST_SUITE_PATH" == *"/finality/"* ]]; then
        # Finality: handle both capella (finality/pyspec_tests) and deneb (finality/finality/pyspec_tests)
        if [[ "$TEST_SUITE_PATH" == *"/finality/finality/pyspec_tests" ]]; then
            # Deneb: remove /finality/pyspec_tests
            OUTPUT_DIR="${TEST_SUITE_PATH%/*/*}/${OUTPUT_SUFFIX}"
        else
            # Capella: remove /pyspec_tests
            OUTPUT_DIR="${TEST_SUITE_PATH%/*}/${OUTPUT_SUFFIX}"
        fi
    elif [[ "$TEST_SUITE_PATH" == *"/random/"* ]]; then
        # Random: remove /random/pyspec_tests
        OUTPUT_DIR="${TEST_SUITE_PATH%/*/*}/${OUTPUT_SUFFIX}"
    else
        OUTPUT_DIR="${TEST_SUITE_PATH}/${OUTPUT_SUFFIX}"
    fi
    
    python3 Converter/run_test_suite.py \
      "$TEST_SUITE_PATH" \
      --spectec-bin ./spectec-core \
      --fork "$FORK_NAME" \
      --run-mode run-sl \
      --workflow "$WORKFLOW_MODE" \
      --output-dir "$OUTPUT_DIR" \
      -v
}

# Fork별 테스트 실행 함수
run_fork_tests() {
    local FORK_NAME="$1"  # deneb or capella
    local FORK_START_TIME=$(date +%s)
    
    echo "=========================================="
    echo "=========================================="
    echo "  ${FORK_NAME^^} FORK 테스트 시작"
    echo "=========================================="
    echo "=========================================="
    echo ""
    
    # Sequential mode tests
    echo "=========================================="
    echo "[Sequential Mode] ${FORK_NAME^^} 테스트 실행"
    echo "=========================================="
    echo ""
    
    # 1. Sanity 테스트 (sequential)
    echo "=========================================="
    echo "[1/3] Sanity 테스트 실행 중... (sequential mode)"
    echo "=========================================="
    run_test_suite "Converter/OfficialTestSuite/${FORK_NAME}/sanity/blocks/pyspec_tests" "sequential" "_sanity_sequential"
    echo ""
    echo "✅ Sanity 테스트 완료"
    echo ""
    
    # 2. Finality 테스트 (sequential)
    echo "=========================================="
    echo "[2/3] Finality 테스트 실행 중... (sequential mode)"
    echo "=========================================="
    # Handle different path structures: deneb has finality/finality/pyspec_tests, capella has finality/pyspec_tests
    if [[ "$FORK_NAME" == "deneb" ]]; then
        run_test_suite "Converter/OfficialTestSuite/${FORK_NAME}/finality/finality/pyspec_tests" "sequential" "_finality_sequential"
    else
        run_test_suite "Converter/OfficialTestSuite/${FORK_NAME}/finality/pyspec_tests" "sequential" "_finality_sequential"
    fi
    echo ""
    echo "✅ Finality 테스트 완료"
    echo ""
    
    # 3. Random 테스트 (sequential)
    echo "=========================================="
    echo "[3/3] Random 테스트 실행 중... (sequential mode)"
    echo "=========================================="
    run_test_suite "Converter/OfficialTestSuite/${FORK_NAME}/random/random/pyspec_tests" "sequential" "_random_sequential"
    echo ""
    echo "✅ Random 테스트 완료"
    echo ""
    
    # Independent mode tests
    echo "=========================================="
    echo "[Independent Mode] ${FORK_NAME^^} 테스트 실행"
    echo "=========================================="
    echo ""
    
    # 1. Sanity 테스트 (independent)
    echo "=========================================="
    echo "[1/3] Sanity 테스트 실행 중... (independent mode)"
    echo "=========================================="
    run_test_suite "Converter/OfficialTestSuite/${FORK_NAME}/sanity/blocks/pyspec_tests" "independent" "_sanity_independent"
    echo ""
    echo "✅ Sanity 테스트 완료"
    echo ""
    
    # 2. Finality 테스트 (independent)
    echo "=========================================="
    echo "[2/3] Finality 테스트 실행 중... (independent mode)"
    echo "=========================================="
    # Handle different path structures: deneb has finality/finality/pyspec_tests, capella has finality/pyspec_tests
    if [[ "$FORK_NAME" == "deneb" ]]; then
        run_test_suite "Converter/OfficialTestSuite/${FORK_NAME}/finality/finality/pyspec_tests" "independent" "_finality_independent"
    else
        run_test_suite "Converter/OfficialTestSuite/${FORK_NAME}/finality/pyspec_tests" "independent" "_finality_independent"
    fi
    echo ""
    echo "✅ Finality 테스트 완료"
    echo ""
    
    # 3. Random 테스트 (independent)
    echo "=========================================="
    echo "[3/3] Random 테스트 실행 중... (independent mode)"
    echo "=========================================="
    run_test_suite "Converter/OfficialTestSuite/${FORK_NAME}/random/random/pyspec_tests" "independent" "_random_independent"
    echo ""
    echo "✅ Random 테스트 완료"
    echo ""
    
    # Fork별 실행 시간 계산
    local FORK_END_TIME=$(date +%s)
    local FORK_ELAPSED_TIME=$((FORK_END_TIME - FORK_START_TIME))
    local FORK_HOURS=$((FORK_ELAPSED_TIME / 3600))
    local FORK_MINUTES=$(((FORK_ELAPSED_TIME % 3600) / 60))
    local FORK_SECONDS=$((FORK_ELAPSED_TIME % 60))
    local FORK_HOURS_DECIMAL=$(awk "BEGIN {printf \"%.2f\", $FORK_ELAPSED_TIME / 3600}")
    
    echo "=========================================="
    echo "  ${FORK_NAME^^} FORK 테스트 완료!"
    echo "=========================================="
    printf "${FORK_NAME^^} 실행 시간: %02d:%02d:%02d (%.2f 시간, %d초)\n" $FORK_HOURS $FORK_MINUTES $FORK_SECONDS $FORK_HOURS_DECIMAL $FORK_ELAPSED_TIME
    echo "=========================================="
    echo ""
}

echo "=========================================="
echo "전체 테스트 스위트 실행 시작"
echo "=========================================="
echo ""

# Deneb 테스트 실행
run_fork_tests "deneb"

echo ""
echo ""

# Capella 테스트 실행
run_fork_tests "capella"

# 전체 종료 시간 기록 및 실행 시간 계산
TOTAL_END_TIME=$(date +%s)
TOTAL_ELAPSED_TIME=$((TOTAL_END_TIME - TOTAL_START_TIME))
TOTAL_HOURS=$((TOTAL_ELAPSED_TIME / 3600))
TOTAL_MINUTES=$(((TOTAL_ELAPSED_TIME % 3600) / 60))
TOTAL_SECONDS=$((TOTAL_ELAPSED_TIME % 60))
TOTAL_HOURS_DECIMAL=$(awk "BEGIN {printf \"%.2f\", $TOTAL_ELAPSED_TIME / 3600}")

echo ""
echo "=========================================="
echo "=========================================="
echo "모든 테스트 스위트 실행 완료!"
echo "=========================================="
echo "=========================================="
echo ""
echo "=========================================="
echo "전체 실행 시간 요약"
echo "=========================================="
printf "총 실행 시간: %02d:%02d:%02d (%.2f 시간, %d초)\n" $TOTAL_HOURS $TOTAL_MINUTES $TOTAL_SECONDS $TOTAL_HOURS_DECIMAL $TOTAL_ELAPSED_TIME
echo "=========================================="

