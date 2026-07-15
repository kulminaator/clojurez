#!/bin/bash
# Lint checks for GC memory invariant violations.
# Ensures all Clojure value data comes from the GC allocator.
#
# Exit code 0 = pass, 1 = violations found.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SRC_DIR="$PROJECT_DIR/src/zig"

FAIL=0

echo "=== GC Invariant Lint Checks ==="
echo ""

# Check 1: Flag direct Value construction with heap-backed string fields outside value.zig
# GcStr is private to value.zig, so direct .string/.symbol/.keyword/.regex construction
# should fail at compile time. This check catches any code that slipped through.
echo "Check 1: Direct Value{ .string/.symbol/.keyword/.regex } construction outside value.zig"
VIOLATIONS=$(grep -rn 'Value{.*\.string\b\|Value{.*\.symbol\b\|Value{.*\.keyword\b\|Value{.*\.regex\b' \
    "$SRC_DIR" --include="*.zig" 2>/dev/null | grep -v 'value\.zig\|test_' || true)
if [ -n "$VIOLATIONS" ]; then
    echo "  FAIL: Found violations:"
    echo "$VIOLATIONS" | sed 's/^/    /'
    FAIL=1
else
    echo "  PASS: No violations"
fi
echo ""

# Check 2: Flag direct GcStr construction outside value.zig
# GcStr is a private struct — code outside value.zig cannot reference it.
echo "Check 2: Direct GcStr construction outside value.zig"
VIOLATIONS=$(grep -rn 'GcStr\.init\|GcStr{' \
    "$SRC_DIR" --include="*.zig" 2>/dev/null | grep -v 'value\.zig' || true)
if [ -n "$VIOLATIONS" ]; then
    echo "  FAIL: Found violations:"
    echo "$VIOLATIONS" | sed 's/^/    /'
    FAIL=1
else
    echo "  PASS: No violations (GcStr is properly private)"
fi
echo ""

# Check 3: Flag shallowClone calls that ignore the return value (shouldn't happen)
echo "Check 3: shallowClone calls that ignore return value"
VIOLATIONS=$(grep -rn 'shallowClone(' "$SRC_DIR" --include="*.zig" 2>/dev/null | grep -v 'try\|catch\|fn shallowClone' || true)
if [ -n "$VIOLATIONS" ]; then
    echo "  WARN: Found shallowClone calls without try/catch:"
    echo "$VIOLATIONS" | sed 's/^/    /'
    # This is a warning, not a failure — could be valid in some contexts
else
    echo "  PASS: All shallowClone calls handle errors"
fi
echo ""

# Check 4: Verify symValue/symValueOwned are the only symbol creation paths
echo "Check 4: Symbol creation uses factory functions"
VIOLATIONS=$(grep -rn '\.symbol\s*=' "$SRC_DIR" --include="*.zig" 2>/dev/null | grep -v 'value\.zig\|test_\|\.symbol\.slice\|\.symbol\s*==\|activeTag.*symbol\|meta\.activeTag.*symbol\|getType.*symbol\|\.symbol\s*=>' || true)
if [ -n "$VIOLATIONS" ]; then
    echo "  WARN: Found potential direct .symbol assignment:"
    echo "$VIOLATIONS" | sed 's/^/    /'
else
    echo "  PASS: No direct .symbol assignment outside value.zig"
fi
echo ""

# Check 5: Flag direct pointer struct construction outside value.zig
# These structs are large (64-256+ bytes) with atomic fields, allocator fields,
# nested ArrayLists. Accidental stack allocation is impractical, but we lint
# to prevent any future violations.
# Types: FnData, AtomData, FutureData, PromiseData, RecordData, ExceptionData,
#        RefData, MultimethodData, ConsData, ChunkData, ChunkedConsData, LazySeqThunk
echo "Check 5: Direct pointer struct construction outside value.zig"
VIOLATIONS=$(grep -rn 'FnData{\|AtomData{\|FutureData{\|PromiseData{\|RecordData{\|ExceptionData{\|RefData{\|MultimethodData{\|ConsData{\|ChunkData{\|ChunkedConsData{\|LazySeqThunk{' \
    "$SRC_DIR" --include="*.zig" 2>/dev/null | grep -v 'value\.zig\|test_' || true)
if [ -n "$VIOLATIONS" ]; then
    echo "  FAIL: Found direct pointer struct construction:"
    echo "$VIOLATIONS" | sed 's/^/    /'
    FAIL=1
else
    echo "  PASS: No direct pointer struct construction outside value.zig"
fi
echo ""

# Check 6: Flag direct collection data construction outside value.zig
# ListData, VectorData, MapData, SetData, QueueData are private (Phase 6).
# This lint check catches any code that somehow bypasses the compile-time enforcement.
echo "Check 6: Direct collection data construction outside value.zig"
VIOLATIONS=$(grep -rn 'ListData{\|VectorData{\|MapData{\|SetData{\|QueueData{' \
    "$SRC_DIR" --include="*.zig" 2>/dev/null | grep -v 'value\.zig\|test_' || true)
if [ -n "$VIOLATIONS" ]; then
    echo "  FAIL: Found direct collection data construction:"
    echo "$VIOLATIONS" | sed 's/^/    /'
    FAIL=1
else
    echo "  PASS: No direct collection data construction outside value.zig"
fi
echo ""

# Summary
if [ $FAIL -eq 0 ]; then
    echo "RESULT: All GC invariant checks passed."
    exit 0
else
    echo "RESULT: GC invariant violations found. See above."
    exit 1
fi
