// RUN: triton-opt %s --allocate-shared-memory --convert-triton-gpu-to-llvm --convert-nv-gpu-to-llvm | mlir-translate -mlir-to-llvmir | opt -S -O1 | FileCheck %s

// Check the optimized LLVMIR, since InstCombine makes the linear layout
// logic understandable enough (in simple cases) to check correctness by eye.

#trivial_layout = #ttg.linear<{register = [], lane = [[1], [2], [4], [8], [16]], warp = [], block = []}>
#trivial_layout_wider = #ttg.linear<{register = [[32]], lane = [[1], [2], [4], [8], [16]], warp = [], block = []}>
#trivial_layout_wider_reg_stride_1 = #ttg.linear<{register = [[1]], lane = [[2], [4], [8], [16], [32]], warp = [], block = []}>
#trivial_2d_one_col = #ttg.linear<{register = [[0, 1]], lane = [[1, 0], [2, 0], [4, 0], [8, 0], [16, 0]], warp = [], block = []}>
#span_2d_cols = #ttg.linear<{register = [[1, 0]], lane = [[2, 0], [4, 0], [8, 0], [16, 0], [0, 1]], warp = [], block = []}>

module attributes {"ttg.num-ctas" = 1 : i32, "ttg.num-warps" = 1 : i32, "ttg.threads-per-warp" = 32 : i32} {

// Each source element is mapped to a single thread, so we expect one index shuffle.
// CHECK-LABEL: @gather_warp_local_trivial
tt.func private @gather_warp_local_trivial(%arg0: tensor<32xi32, #trivial_layout>, %arg1: tensor<32xf32, #trivial_layout>) -> tensor<32xf32, #trivial_layout> {
  // CHECK-NEXT: [[SRC:%.*]] = extractvalue { float } %1, 0
  // CHECK-NEXT: [[IDX:%.*]] = extractvalue { i32 } %0, 0

  // CHECK-NEXT: [[LANEID:%.*]] = and i32 [[IDX]], 31

  // CHECK-NEXT: [[VALUE:%.*]] = bitcast float [[SRC]] to i32
  // CHECK-NEXT: [[RES_i32:%.*]] = tail call i32 @llvm.nvvm.shfl.sync.idx.i32(i32 -1, i32 [[VALUE]], i32 [[LANEID]], i32 31)
  // CHECK-NEXT: [[RES:%.*]] = bitcast i32 [[RES_i32]] to float
  %0 = tt.gather %arg1[%arg0] {axis = 0 : i32} : (tensor<32xf32, #trivial_layout>, tensor<32xi32, #trivial_layout>) -> tensor<32xf32, #trivial_layout>

  // CHECK-NEXT: ret float [[RES]]
  tt.return %0 : tensor<32xf32, #trivial_layout>
}

// Same as above, but there are two index elements per thread. Expect 2 index shuffles
// with the results packed together.
// CHECK-LABEL: @gather_warp_local_larger_output
tt.func private @gather_warp_local_larger_output(%arg0: tensor<64xi32, #trivial_layout_wider>, %arg1: tensor<32xf32, #trivial_layout>) -> tensor<64xf32, #trivial_layout_wider> {
  // CHECK-NEXT: [[SRC:%.*]] = extractvalue { float } %1, 0
  // CHECK-NEXT: [[IDX0:%.*]] = extractvalue { i32, i32 } %0, 0
  // CHECK-NEXT: [[IDX1:%.*]] = extractvalue { i32, i32 } %0, 1

  // CHECK-NEXT: [[LANEID0:%.*]] = and i32 [[IDX0]], 31

  // CHECK-NEXT: [[VALUE:%.*]] = bitcast float [[SRC]] to i32
  // CHECK-NEXT: [[RES0_i32:%.*]] = tail call i32 @llvm.nvvm.shfl.sync.idx.i32(i32 -1, i32 [[VALUE]], i32 [[LANEID0]], i32 31)
  // CHECK-NEXT: [[RES0:%.*]] = bitcast i32 [[RES0_i32]] to float

  // CHECK-NEXT: [[LANEID1:%.*]] = and i32 [[IDX1]], 31
  // CHECK-NEXT: [[RES1_i32:%.*]] = tail call i32 @llvm.nvvm.shfl.sync.idx.i32(i32 -1, i32 [[VALUE]], i32 [[LANEID1]], i32 31)
  // CHECK-NEXT: [[RES1:%.*]] = bitcast i32 [[RES1_i32]] to float

  %0 = tt.gather %arg1[%arg0] {axis = 0 : i32} : (tensor<32xf32, #trivial_layout>, tensor<64xi32, #trivial_layout_wider>) -> tensor<64xf32, #trivial_layout_wider>

  // CHECK-NEXT: [[PACKED0:%.*]] = insertvalue { float, float } undef, float [[RES0]], 0
  // CHECK-NEXT: [[PACKED1:%.*]] = insertvalue { float, float } [[PACKED0]], float [[RES1]], 1
  // CHECK-NEXT: ret { float, float } [[PACKED1]]
  tt.return %0 : tensor<64xf32, #trivial_layout_wider>
}

// Each thread has 2 elements of the source tensor, strided 32 apart, so we
// expect two index shuffles, using the MSB to select between the two.
// CHECK-LABEL: @gather_warp_local_larger_input
tt.func private @gather_warp_local_larger_input(%arg0: tensor<32xi32, #trivial_layout>, %arg1: tensor<64xf32, #trivial_layout_wider>) -> tensor<32xf32, #trivial_layout> {
  // CHECK-NEXT: [[SRC0:%.*]] = extractvalue { float, float } %1, 0
  // CHECK-NEXT: [[SRC1:%.*]] = extractvalue { float, float } %1, 1
  // CHECK-NEXT: [[IDX:%.*]] = extractvalue { i32 } %0, 0

  // CHECK-NEXT: [[REGID:%.*]] = and i32 [[IDX]], 32
  // CHECK-NEXT: [[LANEID:%.*]] = and i32 [[IDX]], 31

  // CHECK-NEXT: [[VALUE:%.*]] = bitcast float [[SRC0]] to i32
  // CHECK-NEXT: [[RES0:%.*]] = tail call i32 @llvm.nvvm.shfl.sync.idx.i32(i32 -1, i32 [[VALUE]], i32 [[LANEID]], i32 31)

  // CHECK-NEXT: [[VALUE:%.*]] = bitcast float [[SRC1]] to i32
  // CHECK-NEXT: [[RES1:%.*]] = tail call i32 @llvm.nvvm.shfl.sync.idx.i32(i32 -1, i32 [[VALUE]], i32 [[LANEID]], i32 31)
  %0 = tt.gather %arg1[%arg0] {axis = 0 : i32} : (tensor<64xf32, #trivial_layout_wider>, tensor<32xi32, #trivial_layout>) -> tensor<32xf32, #trivial_layout>

  // CHECK-NEXT: [[PICK:%.*]] = icmp eq i32 [[REGID]], 0
  // CHECK-NEXT: [[RES_i32:%.*]] = select i1 [[PICK]], i32 [[RES0]], i32 [[RES1]]
  // CHECK-NEXT: [[RES:%.*]] = bitcast i32 [[RES_i32]] to float

  // CHECK-NEXT: ret float [[RES]]
  tt.return %0 : tensor<32xf32, #trivial_layout>
}

// Same as above, except the RegID comes from the LSB.
// CHECK-LABEL: @gather_warp_local_larger_input_stride_1
tt.func private @gather_warp_local_larger_input_stride_1(%arg0: tensor<32xi32, #trivial_layout>, %arg1: tensor<64xf32, #trivial_layout_wider_reg_stride_1>) -> tensor<32xf32, #trivial_layout> {
  // CHECK-NEXT: [[SRC0:%.*]] = extractvalue { float, float } %1, 0
  // CHECK-NEXT: [[SRC1:%.*]] = extractvalue { float, float } %1, 1
  // CHECK-NEXT: [[IDX:%.*]] = extractvalue { i32 } %0, 0

  // CHECK-NEXT: [[REGID:%.*]] = and i32 [[IDX]], 1
  // CHECK-NEXT: [[TMP:%.*]] = lshr i32 [[IDX]], 1
  // CHECK-NEXT: [[LANEID:%.*]] = and i32 [[TMP]], 31

  // CHECK-NEXT: [[VALUE:%.*]] = bitcast float [[SRC0]] to i32
  // CHECK-NEXT: [[RES0:%.*]] = tail call i32 @llvm.nvvm.shfl.sync.idx.i32(i32 -1, i32 [[VALUE]], i32 [[LANEID]], i32 31)

  // CHECK-NEXT: [[VALUE:%.*]] = bitcast float [[SRC1]] to i32
  // CHECK-NEXT: [[RES1:%.*]] = tail call i32 @llvm.nvvm.shfl.sync.idx.i32(i32 -1, i32 [[VALUE]], i32 [[LANEID]], i32 31)
  %0 = tt.gather %arg1[%arg0] {axis = 0 : i32} : (tensor<64xf32, #trivial_layout_wider_reg_stride_1>, tensor<32xi32, #trivial_layout>) -> tensor<32xf32, #trivial_layout>

  // CHECK-NEXT: [[PICK:%.*]] = icmp eq i32 [[REGID]], 0
  // CHECK-NEXT: [[RES_i32:%.*]] = select i1 [[PICK]], i32 [[RES0]], i32 [[RES1]]
  // CHECK-NEXT: [[RES:%.*]] = bitcast i32 [[RES_i32]] to float

  // CHECK-NEXT: ret float [[RES]]
  tt.return %0 : tensor<32xf32, #trivial_layout>
}

// Each thread has 1 element in 2 gather columns, so this is the same as the
// trivial case except now it's 2D. We expect 2 independent index shuffles.
// CHECK-LABEL: @gather_2d_trivial
tt.func private @gather_2d_trivial(%arg0: tensor<32x2xi32, #trivial_2d_one_col>, %arg1: tensor<32x2xf32, #trivial_2d_one_col>) -> tensor<32x2xf32, #trivial_2d_one_col> {
  // CHECK-NEXT: [[SRC0:%.*]] = extractvalue { float, float } %1, 0
  // CHECK-NEXT: [[SRC1:%.*]] = extractvalue { float, float } %1, 1
  // CHECK-NEXT: [[IDX0:%.*]] = extractvalue { i32, i32 } %0, 0
  // CHECK-NEXT: [[IDX1:%.*]] = extractvalue { i32, i32 } %0, 1

  // CHECK-NEXT: {{%.*}} = and i32 [[IDX0]], 32
  // CHECK-NEXT: {{%.*}} = icmp eq i32
  // CHECK-NEXT: [[LANEID0:%.*]] = and i32 [[IDX0]], 31
  // CHECK-NEXT: [[VALUE0:%.*]] = bitcast float [[SRC0]] to i32
  // CHECK-NEXT: [[RES0_i32:%.*]] = tail call i32 @llvm.nvvm.shfl.sync.idx.i32(i32 -1, i32 [[VALUE0]], i32 [[LANEID0]], i32 31)
  // CHECK-NEXT: [[RES0:%.*]] = bitcast i32 [[RES0_i32]] to float

  // CHECK-NEXT: {{%.*}} = select i1
  // CHECK-NEXT: [[LANEID1:%.*]] = and i32 [[IDX1]], 31
  // CHECK-NEXT: [[VALUE1:%.*]] = bitcast float [[SRC1]] to i32
  // CHECK-NEXT: [[RES1_i32:%.*]] = tail call i32 @llvm.nvvm.shfl.sync.idx.i32(i32 -1, i32 [[VALUE1]], i32 [[LANEID1]], i32 31)
  // CHECK-NEXT: [[RES1:%.*]] = bitcast i32 [[RES1_i32]] to float

  %0 = tt.gather %arg1[%arg0] {axis = 0 : i32} : (tensor<32x2xf32, #trivial_2d_one_col>, tensor<32x2xi32, #trivial_2d_one_col>) -> tensor<32x2xf32, #trivial_2d_one_col>

  // CHECK-NEXT: [[PACKED0:%.*]] = insertvalue { float, float } undef, float {{%.*}}, 0
  // CHECK-NEXT: [[PACKED1:%.*]] = insertvalue { float, float } [[PACKED0]], float {{%.*}}, 1
  // CHECK-NEXT: ret { float, float } [[PACKED1]]
  tt.return %0 : tensor<32x2xf32, #trivial_2d_one_col>
}

// The single warp is split into two columns. Each column has half contiguous
// threads, each with 2 contiguous elements. Expect 4 index shuffles: two per
// column. Thus, the index should be dependent on the thread id, since the
// register alone is not enough to determine the column.
// CHECK-LABEL: @gather_2d_span_2
tt.func private @gather_2d_span_2(%arg0: tensor<32x2xi32, #span_2d_cols>, %arg1: tensor<32x2xf32, #span_2d_cols>) -> tensor<32x2xf32, #span_2d_cols> {
  // CHECK-NEXT: [[SRC0:%.*]] = extractvalue { float, float } %1, 0
  // CHECK-NEXT: [[SRC1:%.*]] = extractvalue { float, float } %1, 1
  // CHECK-NEXT: [[IDX0:%.*]] = extractvalue { i32, i32 } %0, 0
  // CHECK-NEXT: [[IDX1:%.*]] = extractvalue { i32, i32 } %0, 1

  // This uses tid to select between the two columns:
  // CHECK-NEXT: [[TID:%.*]] = tail call i32 @llvm.nvvm.read.ptx.sreg.tid.x()
  // CHECK-NEXT: [[TMP_COL:%.*]] = shl{{.*}} i32 [[TID]], 1
  // CHECK-NEXT: [[COL:%.*]] = and i32 [[TMP_COL]], 32

  // Break the index into reg and thread (within column) components:
  // CHECK-NEXT: [[REGID0:%.*]] = and i32 [[IDX0]], 1
  // CHECK-NEXT: [[MASKED0:%.*]] = and i32 [[IDX0]], 62
  // CHECK-NEXT: [[TMP_IDX0:%.*]] = or i32 [[MASKED0]], [[COL]]
  // CHECK-NEXT: [[SHUFFLE_IDX0:%.*]] = lshr exact i32 [[TMP_IDX0]], 1

  // CHECK-NEXT: [[VALUE0:%.*]] = bitcast float [[SRC0]] to i32
  // CHECK-NEXT: [[SRES0:%.*]] = tail call i32 @llvm.nvvm.shfl.sync.idx.i32(i32 -1, i32 [[VALUE0]], i32 [[SHUFFLE_IDX0]], i32 31)
  // CHECK-NEXT: [[VALUE1:%.*]] = bitcast float [[SRC1]] to i32
  // CHECK-NEXT: [[SRES1:%.*]] = tail call i32 @llvm.nvvm.shfl.sync.idx.i32(i32 -1, i32 [[VALUE1]], i32 [[SHUFFLE_IDX0]], i32 31)

  // Use the reg id to select between the two results:
  // CHECK-NEXT: [[PICK0:%.*]] = icmp eq i32 [[REGID0]], 0
  // CHECK-NEXT: [[RES0_i32:%.*]] = select i1 [[PICK0]], i32 [[SRES0]], i32 [[SRES1]]
  // CHECK-NEXT: [[RES0:%.*]] = bitcast i32 [[RES0_i32]] to float

  // CHECK-NEXT: [[REGID1:%.*]] = and i32 [[IDX1]], 1
  // CHECK-NEXT: [[MASKED1:%.*]] = and i32 [[IDX1]], 62
  // CHECK-NEXT: [[TMP_IDX1:%.*]] = or i32 [[MASKED1]], [[COL]]
  // CHECK-NEXT: [[SHUFFLE_IDX1:%.*]] = lshr exact i32 [[TMP_IDX1]], 1

  // CHECK-NEXT: [[SRES0:%.*]] = tail call i32 @llvm.nvvm.shfl.sync.idx.i32(i32 -1, i32 [[VALUE0]], i32 [[SHUFFLE_IDX1]], i32 31)
  // CHECK-NEXT: [[SRES1:%.*]] = tail call i32 @llvm.nvvm.shfl.sync.idx.i32(i32 -1, i32 [[VALUE1]], i32 [[SHUFFLE_IDX1]], i32 31)

  // CHECK-NEXT: [[PICK1:%.*]] = icmp eq i32 [[REGID1]], 0
  // CHECK-NEXT: [[RES1_i32:%.*]] = select i1 [[PICK1]], i32 [[SRES0]], i32 [[SRES1]]
  // CHECK-NEXT: [[RES1:%.*]] = bitcast i32 [[RES1_i32]] to float

  %0 = tt.gather %arg1[%arg0] {axis = 0 : i32} : (tensor<32x2xf32, #span_2d_cols>, tensor<32x2xi32, #span_2d_cols>) -> tensor<32x2xf32, #span_2d_cols>

  // CHECK-NEXT: [[PACKED0:%.*]] = insertvalue { float, float } undef, float [[RES0]], 0
  // CHECK-NEXT: [[PACKED1:%.*]] = insertvalue { float, float } [[PACKED0]], float [[RES1]], 1
  // CHECK-NEXT: ret { float, float } [[PACKED1]]
  tt.return %0 : tensor<32x2xf32, #span_2d_cols>
}

// Keep LLVM from DCE'ing the above functions. Use volatile stores to stop LLVM
// from removing unused function results.
tt.func @anchor_warp1(%ptr: !llvm.ptr,
    %arg0: tensor<32xi32, #trivial_layout>,
    %arg1: tensor<32xf32, #trivial_layout>,
    %arg2: tensor<64xi32, #trivial_layout_wider>,
    %arg3: tensor<64xf32, #trivial_layout_wider>,
    %arg4: tensor<64xf32, #trivial_layout_wider_reg_stride_1>,
    %arg5: tensor<32x2xi32, #trivial_2d_one_col>,
    %arg6: tensor<32x2xf32, #trivial_2d_one_col>,
    %arg7: tensor<32x2xi32, #span_2d_cols>,
    %arg8: tensor<32x2xf32, #span_2d_cols>) {

  %0 = tt.call @gather_warp_local_trivial(%arg0, %arg1) : (tensor<32xi32, #trivial_layout>, tensor<32xf32, #trivial_layout>) -> tensor<32xf32, #trivial_layout>
  %1 = builtin.unrealized_conversion_cast %0 : tensor<32xf32, #trivial_layout> to !llvm.struct<(f32)>
  llvm.store volatile %1, %ptr : !llvm.struct<(f32)>, !llvm.ptr

  %2 = tt.call @gather_warp_local_larger_output(%arg2, %arg1) : (tensor<64xi32, #trivial_layout_wider>, tensor<32xf32, #trivial_layout>) -> tensor<64xf32, #trivial_layout_wider>
  %3 = builtin.unrealized_conversion_cast %2 : tensor<64xf32, #trivial_layout_wider> to !llvm.struct<(f32, f32)>
  llvm.store volatile %3, %ptr : !llvm.struct<(f32, f32)>, !llvm.ptr

  %4 = tt.call @gather_warp_local_larger_input(%arg0, %arg3) : (tensor<32xi32, #trivial_layout>, tensor<64xf32, #trivial_layout_wider>) -> tensor<32xf32, #trivial_layout>
  %5 = builtin.unrealized_conversion_cast %4 : tensor<32xf32, #trivial_layout> to !llvm.struct<(f32)>
  llvm.store volatile %5, %ptr : !llvm.struct<(f32)>, !llvm.ptr

  %6 = tt.call @gather_warp_local_larger_input_stride_1(%arg0, %arg4) : (tensor<32xi32, #trivial_layout>, tensor<64xf32, #trivial_layout_wider_reg_stride_1>) -> tensor<32xf32, #trivial_layout>
  %7 = builtin.unrealized_conversion_cast %6 : tensor<32xf32, #trivial_layout> to !llvm.struct<(f32)>
  llvm.store volatile %7, %ptr : !llvm.struct<(f32)>, !llvm.ptr

  %8 = tt.call @gather_2d_trivial(%arg5, %arg6) : (tensor<32x2xi32, #trivial_2d_one_col>, tensor<32x2xf32, #trivial_2d_one_col>) -> tensor<32x2xf32, #trivial_2d_one_col>
  %9 = builtin.unrealized_conversion_cast %8 : tensor<32x2xf32, #trivial_2d_one_col> to !llvm.struct<(f32, f32)>
  llvm.store volatile %9, %ptr : !llvm.struct<(f32, f32)>, !llvm.ptr

  %10 = tt.call @gather_2d_span_2(%arg7, %arg8) : (tensor<32x2xi32, #span_2d_cols>, tensor<32x2xf32, #span_2d_cols>) -> tensor<32x2xf32, #span_2d_cols>
  %11 = builtin.unrealized_conversion_cast %10 : tensor<32x2xf32, #span_2d_cols> to !llvm.struct<(f32, f32)>
  llvm.store volatile %11, %ptr : !llvm.struct<(f32, f32)>, !llvm.ptr

  tt.return
}

}
