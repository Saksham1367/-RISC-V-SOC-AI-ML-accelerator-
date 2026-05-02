# SEDA Project — Research Literature Context Document
## For Claude Code Development Context

**Purpose**: This document synthesizes key findings, architectural patterns, design decisions, and implementation-relevant details from the academic literature directly relevant to building the SEDA (Sparse Event-Driven Neural Accelerator) SoC. Feed this document to Claude Code as project context to ensure RTL design, verification, and firmware decisions align with proven research methodologies.

**Project Summary**: SEDA is a RISC-V RV32IM SoC with a tightly-coupled 8×8 INT8 systolic array ML accelerator featuring three-gate sparsity filtering (zero-detection, change-detection, spike-threshold), custom ISA extensions (mm.* instructions via custom-0 opcode), targeting the Sipeed Tang Nano 20K (Gowin GW2AR-18) FPGA and SkyWater SKY130 ASIC tapeout via OpenLane.

---

## 1. SPARSITY-AWARE COMPUTATION (Gate 1: Zero Detector)

### 1.1 NVIDIA 2:4 Structured Sparsity — The Industry Benchmark
**Paper**: Mishra et al., "Accelerating Sparse Deep Neural Networks," NVIDIA, arXiv:2104.08378, 2021 (280 citations)

**Key Technical Details for SEDA Implementation**:
- **2:4 sparsity pattern**: Every group of 4 consecutive values must contain at least 2 zeros → 50% sparsity guaranteed. This is more conservative than SEDA's approach (which targets 60-90% natural ReLU sparsity) but provides guaranteed minimum.
- **Compressed storage format**: Non-zero values stored contiguously + 2-bit metadata per group-of-4 indicating positions of the two non-zero elements. Metadata overhead: 2 bits per 4 elements = 12.5%. Total compression: 2× (50% zeros removed, metadata is small).
- **Sparse Tensor Core operation**: The selector logic uses the 2-bit metadata indices to select which elements of the dense matrix B to multiply with the compressed sparse matrix A. This is done per-cycle in the data path, not as a pre-processing step.
- **Training workflow**: Dense train → one-shot magnitude pruning to 2:4 pattern → retrain with same hyperparameters and fixed sparsity mask → accuracy maintained across vision, NLP, recommendation models.
- **Performance**: 2× math throughput over dense Tensor Cores for GEMM operations.

**SEDA Design Implications**:
- SEDA's zero-detection is more fine-grained (per-element, not 2:4 structured) which means higher potential skip rates but requires per-PE detection logic rather than offline compression.
- SEDA's approach is runtime detection (combinational OR-reduce per PE) vs. NVIDIA's compile-time structured pruning. This is a key differentiator — SEDA handles naturally sparse activations without model modification.
- The ~8 LUT cost per PE for zero-detection is justified by the 60-90% skip rate in ReLU networks, significantly exceeding NVIDIA's 50% structured floor.

### 1.2 FPGA-Based Structured Sparse CNN Accelerator
**Paper**: Zhu et al., "An Efficient Hardware Accelerator for Structured Sparse CNNs on FPGAs," IEEE TVLSI, 2020 (111 citations)

**Key Technical Details**:
- **Sparsewise dataflow**: Skips MAC cycles with zero weights by using a Vector Generator Module (VGM) that matches indices between sparse weights and input activations.
- **Index matching hardware**: The VGM scans compressed weight indices and selects corresponding activation values. This is the FPGA equivalent of what NVIDIA does in silicon.
- **Zero gating**: Uses data statistics to gate unnecessary computations — similar to SEDA's Gate 1 but applied at the weight side rather than activation side.
- **Results on Xilinx ZCU102**: AlexNet 987 img/s, VGG-16 46 img/s, ResNet-50 57 img/s. 1.5×–6.7× speedup and 2.0×–6.0× energy efficiency over prior FPGA accelerators.
- **Bandwidth savings**: Sparsewise dataflow reduces off-chip bandwidth requirements because only non-zero weights are loaded.

**SEDA Design Implications**:
- SEDA should consider implementing both weight-side AND activation-side zero detection for maximum skip rate (two-sided sparsity).
- The VGM concept could be simplified for SEDA since SEDA uses a systolic array (regular dataflow) rather than a custom dataflow — the zero check can be purely combinational at each PE input.

### 1.3 Zero-Activation Skipping for Low-Energy Acceleration
**Paper**: Liu et al., "Efficient Zero-Activation-Skipping for On-Chip Low-Energy CNN Acceleration," IEEE AICAS, 2021

**Key Technical Details**:
- **Position-based activation skipping**: Instead of storing sparse activations in compressed format, this approach tracks positions of non-zero activations and only schedules those for computation.
- **Load balancing without hardware cost**: Achieves balanced workload distribution across PEs by reusing activations, avoiding the load imbalance problem that plagues many sparse accelerators.
- **Measured results**: 7.29× speedup at 90% sparsity for convolutional layers. 2.59× for full VGG16 with ImageNet. Energy efficiency: 1.94 TOPS/W at 100 MHz in UMC 55nm.
- **Sparsity exploitation**: Specifically targets input feature map sparsity (post-ReLU), which is exactly what SEDA's Gate 1 targets.

**SEDA Design Implications**:
- Confirms SEDA's expected 60-90% activation sparsity post-ReLU is realistic and achievable.
- The 7.29× speedup at 90% sparsity provides a theoretical upper bound for SEDA's Gate 1 alone.
- Load balancing across systolic array PEs is less of an issue than in irregular dataflow architectures since the systolic data movement is fixed.

### 1.4 Sparse-PE: Efficient Processing Engine for Sparse CNNs
**Paper**: Qureshi et al., "Sparse-PE: A Performance-Efficient Processing Engine Core for Sparse CNNs," IEEE Access, 2021 (8 citations)

**Key Technical Details**:
- **Binary mask representation**: Each PE maintains a binary mask indicating non-zero positions in its input data. Only non-zero × non-zero products are computed.
- **Multi-threaded PE**: Unlike SEDA's single-threaded PEs, Sparse-PE uses multiple hardware threads to keep the PE busy when one thread stalls on a sparse region. SEDA uses a simpler skip approach instead.
- **Two-sided sparsity**: Exploits zeros in BOTH activations and weights simultaneously.
- **Performance**: 12× over dense NeuroMAX, 4.2× over SCNN, 2.38× over Eyeriss v2, 1.98× over SparTen.
- **Generic design**: Not tied to a specific accelerator architecture — can be used as a standalone sparse dot-product engine.

**SEDA Design Implications**:
- The binary mask approach is more complex than SEDA's simple OR-reduce zero check but offers two-sided sparsity. SEDA's simpler approach is appropriate for the resource-constrained Tang Nano 20K.
- The standalone PE design philosophy aligns with SEDA's parameterized PE approach — each PE is self-contained with its own filtering logic.

### 1.5 SPOTS: Systolic Array + Sparsity Combined
**Paper**: Soltaniyeh et al., "An Accelerator for Sparse CNNs Leveraging Systolic GEMM," ACM TACO, 2022 (27 citations)

**Key Technical Details**:
- **Im2Col + Systolic GEMM**: Converts convolution to matrix multiplication using Image-to-Column transformation, then processes on a systolic array — exactly the approach SEDA should use for CNN inference.
- **Distributed local memories with ring network**: The Im2Col unit uses distributed memories connected via a ring, streaming input feature maps only once. This improves energy efficiency.
- **Dynamic reconfigurability**: The systolic array can split into multiple smaller arrays or operate as a single tall array. This is more flexible than SEDA's fixed 8×8 but adds complexity.
- **Sparsity-aware mapping**: Effectively maps sparse feature maps and weights to PEs, skipping zero operations and unnecessary data movements.
- **Results**: 2.16× faster than Gemmini, 1.74× faster than Eyeriss, 1.63× faster than Sparse-PE. 78× more energy-efficient than CPU, 12× more than GPU.

**SEDA Design Implications**:
- Confirms that systolic array + sparsity is a winning combination (SEDA's exact approach).
- Im2Col transformation should be done in firmware (C code compiled to RV32IM) to save hardware resources on the Tang Nano 20K.
- The ring network for Im2Col is too resource-heavy for SEDA; simpler tiled approach in firmware is sufficient for MNIST-scale workloads.

---

## 2. SYSTOLIC ARRAY ARCHITECTURE (8×8 PE Grid)

### 2.1 Gemmini: The Open-Source RISC-V Systolic Array Reference
**Paper**: Genç et al., "Gemmini: An Agile Systolic Array Generator," UC Berkeley, arXiv:1911.09925, 2019 (73 citations)

**Key Technical Details**:
- **Architecture**: Parameterized NxN systolic array generator integrated with RISC-V Rocket Chip SoC. Supports both Weight Stationary (WS) and Output Stationary (OS) dataflows.
- **Two-level PE hierarchy**: The spatial array is composed of tiles (connected via pipeline registers), each tile containing an array of PEs (connected combinationally). This allows trading off between throughput and timing closure.
- **RISC-V integration**: Uses custom RISC-V instructions (RoCC interface) to control the accelerator. The CPU sends configuration commands and data addresses; the accelerator operates autonomously on data in its local scratchpad.
- **Memory hierarchy**: Local scratchpad (SRAM) in the accelerator + accumulator buffer for partial sums. Data is moved between main memory and scratchpad via DMA.
- **ISA interface**: Custom instructions for: (1) configuring the accelerator, (2) loading data from memory to scratchpad, (3) executing matrix multiply, (4) storing results back. This directly parallels SEDA's mm.load/mm.start/mm.wait/mm.store.
- **Fabrication**: Successfully taped out in TSMC 16nm and Intel 22FFL. Achieves 2-3 orders of magnitude speedup over CPU baseline.
- **Design space exploration**: For edge inference (SEDA's target), a 16×16 array with WS dataflow, 256 KiB scratchpad, and 64 KiB accumulator was found optimal. SEDA's 8×8 with smaller buffers is a scaled-down version appropriate for the Tang Nano 20K's resource constraints.
- **Dataflow comparison**: WS dataflow offers 3× speedup over OS dataflow (from related Gemmini DSE studies). SEDA should strongly consider WS dataflow.

**SEDA Design Implications**:
- Gemmini's RoCC custom instruction interface is the direct precedent for SEDA's mm.* ISA extension. The custom-0 opcode approach is cleaner (doesn't require RoCC infrastructure).
- The two-level tile/PE hierarchy could help SEDA with timing closure on the Gowin FPGA — consider grouping the 8×8 array into 4 tiles of 2×4 PEs each with pipeline registers between tiles.
- Gemmini does NOT have sparsity support — SEDA's sparsity gates are a genuine innovation over this baseline.
- Weight Stationary dataflow is recommended based on Gemmini's findings for edge inference workloads.

### 2.2 SIGMA: Flexible Sparse GEMM Accelerator
**Paper**: Qin et al., "SIGMA: A Sparse and Irregular GEMM Accelerator," HPCA 2020 (444 citations)

**Key Technical Details**:
- **Forwarding Adder Network (FAN)**: Novel reduction tree that flexibly routes partial products to the correct accumulator regardless of sparsity pattern. Solves the load imbalance problem of systolic arrays under sparsity.
- **Flexible interconnect**: Unlike fixed systolic dataflow, SIGMA uses a crossbar-like network to distribute operands to any PE. This enables high utilization at any sparsity level.
- **Performance**: 5.7× better than systolic arrays for irregular sparse matrices. 3× better than state-of-the-art sparse accelerators. 10.8 TFLOPS efficiency at 28nm.
- **Key insight**: Standard systolic arrays suffer from PE underutilization when processing sparse data because the fixed dataflow cannot skip over zeros efficiently. SIGMA solves this but at significantly higher area/power cost.

**SEDA Design Implications**:
- SEDA takes the simpler approach: keep the systolic dataflow (low area, simple control) but add per-PE skip logic. This avoids SIGMA's complex interconnect overhead while still capturing most of the sparsity benefit.
- The trade-off is that SEDA may have slightly lower PE utilization than SIGMA under highly irregular sparsity, but for MNIST-scale workloads with structured ReLU sparsity, this is acceptable.
- SIGMA's 28nm, 65 mm² footprint is orders of magnitude larger than SEDA's target — validates that SEDA's simpler approach is appropriate for edge/FPGA deployment.

### 2.3 Eyeriss v2: Flexible Sparse DNN Accelerator
**Paper**: Chen et al., "Eyeriss v2: A Flexible Accelerator for Emerging DNNs on Mobile Devices," IEEE JETCAS, 2019

**Key Technical Details**:
- **Hierarchical Mesh Network-on-Chip (HM-NoC)**: Flexible on-chip network that adapts to different data reuse patterns across layers. Supports varying amounts of spatial data reuse.
- **Row-Stationary Plus (RS+) dataflow**: Extended version of the original Row-Stationary dataflow that handles a wider variety of layer shapes (depthwise convolutions, pointwise convolutions, etc.).
- **Compressed Sparse Column (CSC) format**: Both weights and activations are stored and processed in compressed format. The PE can directly operate on compressed data without decompression.
- **Sparse PE architecture**: Each PE has logic to skip zero-valued operands. The PE scans through compressed weight and activation streams, only computing non-zero × non-zero products.
- **Results**: With sparse MobileNet at 65nm: 1470.6 inferences/sec, 2560.3 inferences/J. 12.6× faster and 2.5× more energy efficient than Eyeriss v1.
- **Scalability**: HM-NoC enables near-linear performance scaling with PE count.

**SEDA Design Implications**:
- Eyeriss v2's CSC compressed format is too complex for SEDA's resource budget. SEDA's simpler runtime zero-detection is more appropriate.
- The sparse PE concept (skipping zero × zero products) validates SEDA's Gate 1 design at the architectural level.
- Eyeriss v2 does NOT have change detection or spike thresholding — these remain SEDA's unique innovations.

### 2.4 Systolic Array Dataflow Analysis
**Paper**: Raja, "Systolic Array Data Flows for Efficient Matrix Multiplication in DNNs," arXiv, 2024

**Key Technical Details**:
- **Three dataflows compared**: Weight Stationary (WS), Input Stationary (IS), Output Stationary (OS).
- **WS dataflow**: Weights are preloaded and held stationary in PEs. Inputs and partial sums flow through the array. Best for layers where weights are reused many times (convolutions with large batch sizes).
- **OS dataflow**: Partial sums remain in each PE and accumulate. Weights and inputs flow through. Best for reducing partial sum movement (good for large output feature maps).
- **IS dataflow**: Inputs stay in PEs. Best for input reuse (not commonly used).
- **Energy analysis**: Dataflow choice significantly impacts energy consumption. Wrong dataflow can lead to 2-4× energy overhead.

**SEDA Design Implications**:
- For MNIST CNN inference with small batch size (1), **Output Stationary** may be better than Weight Stationary because each image is processed independently and partial sums dominate data movement.
- However, for the 8×8 tiled matrix multiplication approach (where weight tiles are reused across spatial tiles of the feature map), **Weight Stationary** is likely better.
- SEDA should implement WS dataflow as the primary mode, matching Gemmini's recommendation for edge inference. The mm.load instruction should preload weights into PEs before streaming activations.

---

## 3. EVENT-DRIVEN & NEUROMORPHIC COMPUTING (Gate 2: Change Detector, Gate 3: Spike Controller)

### 3.1 Neuromorphic Computing: The Theoretical Foundation
**Paper**: Roy et al., "Towards Spike-Based Machine Intelligence with Neuromorphic Computing," Nature, 2019 (1,751 citations)

**Key Technical Details**:
- **Spike-based encoding**: Information is represented as binary spike events (fire/no-fire) rather than continuous values. This fundamentally reduces data movement and computation — a neuron only communicates when it has something meaningful to say.
- **Event-driven execution**: Computation happens only when a spike (event) arrives, not on every clock cycle. This eliminates idle power in neurons that have no input to process.
- **Temporal coding**: The timing of spikes carries information, not just their presence/absence. Neurons that fire earlier convey stronger signals. This is relevant to SEDA's threshold-based spike gate.
- **Energy efficiency**: Neuromorphic chips like IBM TrueNorth achieve ~70 mW for 1 million neurons vs. ~250W for GPU equivalents — 3,500× energy advantage.
- **Key insight**: The brain processes information using sparse, event-driven, asynchronous computation. Only ~1-5% of neurons fire at any given time, and they only fire when input exceeds a threshold.

**SEDA Design Implications**:
- SEDA's Gate 3 (spike threshold) directly implements the biological neuron firing threshold concept. The programmable threshold register maps to biological membrane potential threshold.
- Gate 2 (change detection) implements the event-driven principle — only compute when input changes.
- SEDA is NOT a full neuromorphic processor (it doesn't use temporal spike coding or synaptic plasticity), but it borrows the key efficiency principles: sparsity, event-driven computation, and threshold-based activation.
- The skip_count CSR provides direct visibility into how much neuromorphic-style efficiency is being achieved.

### 3.2 Intel Loihi: Neuromorphic Research Processor
**Paper**: Davies et al., "Advancing Neuromorphic Computing With Loihi: A Survey of Results and Outlook," Proceedings of the IEEE, 2021 (502 citations)

**Key Technical Details**:
- **Architecture**: 128 neuromorphic cores, each with 1024 compartments (neurons). Fully asynchronous, event-driven data flow. Fabricated at Intel 14nm.
- **Spike-based computation**: Neurons accumulate weighted spike inputs, fire when membrane potential exceeds threshold, then reset. This is the hardware version of SEDA's Gate 3.
- **On-chip learning**: Supports programmable synaptic plasticity (STDP and variants). SEDA does not implement learning, only inference.
- **Sparsity exploitation**: Loihi naturally exploits activity sparsity — neurons that don't fire don't generate any traffic or computation. Achieves orders-of-magnitude energy savings on sparse workloads.
- **Key results**: For event-based data processing (e.g., DVS cameras), Loihi achieves 5× lower latency and 100× lower energy than GPU. For constrained optimization problems, 1000× better energy-delay product than CPU.
- **Limitation**: Loihi uses a completely different programming model (spiking neural networks) that is incompatible with conventional deep learning frameworks. This limits its applicability to standard CNN workloads like MNIST.

**SEDA Design Implications**:
- SEDA bridges the gap between conventional DNN accelerators and neuromorphic processors by adding neuromorphic-inspired efficiency features (change detection, spike threshold) to a conventional systolic array architecture that runs standard quantized CNNs.
- This hybrid approach is SEDA's key innovation — it gets some of the neuromorphic efficiency benefits while remaining compatible with standard ML frameworks and INT8 quantized models.
- Loihi's neuron model (leaky integrate-and-fire) is much more complex than SEDA's simple threshold comparator. SEDA's simplified approach is appropriate for inference-only workloads.

### 3.3 Event-Driven Vision Sensors
**Paper**: Zhou et al., "Computational Event-Driven Vision Sensors for In-Sensor SNNs," Nature Electronics, 2023 (150 citations)

**Key Technical Details**:
- **Change-only sensing**: Sensors detect and output only changes in light intensity, ignoring static portions of the scene. This is the sensor-level equivalent of SEDA's Gate 2 change detector.
- **Temporal resolution**: 5 μs temporal resolution for change detection — changes are detected at microsecond scale, much faster than frame-based cameras.
- **Redundancy elimination**: By only capturing changes, data volume is reduced by orders of magnitude for mostly-static scenes (surveillance, monitoring, etc.).
- **In-sensor computation**: The sensors directly implement synaptic weights, performing the first layer of neural network computation at the sensor. SEDA's Gate 2 performs a similar function at the PE level.

**SEDA Design Implications**:
- Validates the change-detection approach for sequential/video data. SEDA's XOR-based change detector at each PE implements the same principle at the accelerator level.
- For sequential MNIST inference (processing multiple images), Gate 2 will detect that most pixel positions don't change between consecutive digits, especially in regions of white space.
- The shadow register approach (storing previous input for XOR comparison) is validated by the event-driven sensor architecture.
- Expected skip rate from change detection alone: 40-70% for sequential data (matching the paper's findings on temporal redundancy).

### 3.4 SNN Hardware Survey
**Paper**: Bouvier et al., "Spiking Neural Networks Hardware Implementations and Challenges," ACM JETC, 2019 (128 citations)

**Key Technical Details**:
- **Neuron models**: Leaky Integrate-and-Fire (LIF) is the most common hardware neuron model. Parameters: membrane potential, threshold voltage, leak factor, refractory period.
- **Hardware implementations**: Digital implementations typically use counters for membrane potential, comparators for threshold detection, and timers for refractory periods.
- **Threshold detection**: A simple magnitude comparator is sufficient for spike detection. Cost: ~12 gates for 8-bit comparison. This matches SEDA's Gate 3 resource estimate.
- **Event-driven vs. time-driven**: Event-driven implementations only update neurons when they receive spikes, saving significant power. Time-driven implementations update all neurons every clock cycle.

**SEDA Design Implications**:
- SEDA's Gate 3 implements a simplified LIF neuron: compare absolute value of input against threshold, fire (compute) only if above threshold. No leak or refractory period.
- The 12-LUT estimate for SEDA's spike controller aligns with the survey's hardware cost analysis for simple threshold detectors.
- SEDA's approach is time-driven (checks every cycle) but with event-gating (skips computation if below threshold). This is a practical compromise for a systolic array architecture.

---

## 4. RISC-V CUSTOM ISA EXTENSIONS (mm.* Instructions)

### 4.1 RISC-V Extensions for Sparse DNN Acceleration on FPGA
**Paper**: Sabih et al., "Hardware/Software Co-Design of RISC-V Extensions for Accelerating Sparse DNNs on FPGAs," ICFPT, 2024 (5 citations)

**Key Technical Details**:
- **Custom functional units**: Tightly coupled with the RISC-V pipeline, operating in the execute stage. The custom instruction triggers the functional unit, which operates on data from the register file.
- **Semi-structured sparsity encoding**: A few bits in each weight block encode sparsity information about succeeding blocks. The custom functional unit reads this metadata and skips zero-weight MACs.
- **Unstructured sparsity unit**: A variable-cycle sequential MAC that performs only as many multiplications as there are non-zero weights. Takes N cycles for N non-zero elements instead of fixed K cycles for all K elements.
- **Combined design**: Supports both semi-structured and unstructured sparsity in a single accelerator. Achieves up to 5× speedup over baseline RISC-V.
- **Resource efficiency**: Additional FPGA resources consumed are small enough to fit on small FPGAs — validated on TinyML benchmarks (keyword spotting, image classification, person detection).

**SEDA Design Implications**:
- Validates SEDA's approach of adding custom instructions rather than memory-mapped I/O for accelerator control.
- The tight coupling through the RISC-V pipeline (execute stage) is similar to SEDA's approach, though SEDA uses a loosely-coupled model via AXI4 with dedicated control CSRs.
- The resource overhead for custom instructions is minimal — SEDA's decoder extension for custom-0 opcode should add ~100-200 LUTs.
- TinyML benchmark validation is relevant since MNIST is a TinyML-scale workload.

### 4.2 MaRVIn: Mixed-Precision RISC-V Framework
**Paper**: Armeniakos et al., "MaRVIn: Cross-Layer Mixed-Precision RISC-V Framework for DNN Inference," arXiv, 2025

**Key Technical Details**:
- **ISA extensions for mixed precision**: Custom instructions for 2-bit, 4-bit, and 8-bit arithmetic operations. The ALU is enhanced with configurable precision modes.
- **Multi-pumping**: Executes multiple low-precision operations in a single cycle by time-multiplexing the datapath. This effectively increases throughput for quantized operations.
- **Soft SIMD for 2-bit operations**: Packs multiple 2-bit operations into a single 32-bit datapath operation. For 8-bit (SEDA's target), this would be 4 operations per 32-bit word.
- **Pruning-aware quantization**: Combines model pruning with quantization for maximum compression. A greedy DSE approach finds Pareto-optimal configurations.
- **Performance**: Average 17.6× speedup for <1% accuracy loss. Up to 1.8 TOPs/W.

**SEDA Design Implications**:
- SEDA operates at fixed INT8 precision, which is simpler than MaRVIn's mixed-precision approach. However, the soft SIMD concept could be useful if SEDA ever extends to sub-byte precisions.
- The voltage scaling approach for power optimization is not applicable to FPGA but relevant for the SKY130 ASIC tapeout.
- Confirms that RISC-V ISA extensions for DNN workloads is an active and validated research direction.

### 4.3 RISQ-V: Tightly Coupled RISC-V Accelerators
**Paper**: Fritzmann et al., "RISQ-V: Tightly Coupled RISC-V Accelerators for Post-Quantum Cryptography," 2020 (144 citations)

**Key Technical Details**:
- **29 new custom instructions** added to RISC-V ISA for lattice-based cryptography operations (NTT, polynomial arithmetic, modular reduction).
- **Tight pipeline integration**: Accelerators are inserted into the RISC-V pipeline, sharing the register file and data path. Results are written back through the standard writeback stage.
- **Resource reuse**: Custom functional units reuse existing processor resources (multipliers, adders) when possible, reducing area overhead.
- **ASIC implementation**: Cell count increased by 1.6× over base RISC-V — considered moderate for 11.4× speedup gained.
- **Energy reduction**: Up to 92.2% energy reduction through hardware acceleration vs. pure software.

**SEDA Design Implications**:
- The 1.6× area increase for 11.4× speedup validates SEDA's approach of adding custom accelerator hardware to the RISC-V core.
- SEDA's loosely-coupled approach (via AXI4 bus) is different from RISQ-V's tightly-coupled pipeline integration. The trade-off: loosely coupled is simpler to design/verify but has higher latency for accelerator commands.
- For SEDA's mm.wait instruction (which stalls the pipeline), a simple busy-wait polling loop in firmware may be more practical than a true pipeline stall for the initial implementation.

---

## 5. FPGA NEURAL NETWORK INFERENCE & INT8 QUANTIZATION

### 5.1 FPGA DNN Acceleration Survey
**Paper**: Wu et al., "Accelerating Neural Network Inference on FPGA-Based Platforms — A Survey," Electronics, 2021 (71 citations)

**Key Technical Details**:
- **Five acceleration strategies identified**: (1) Reducing computing complexity (pruning, quantization), (2) Increasing computing parallelism (spatial arrays, pipelining), (3) Maximizing data reuse (tiling, blocking), (4) Pruning (weight/activation sparsity), (5) Quantization (INT8, INT4, binary).
- **INT8 quantization**: Post-training quantization to INT8 typically loses <1% accuracy on image classification tasks. For MNIST, INT8 accuracy loss is negligible (<0.5%).
- **Tiling strategy**: Large matrices are broken into tiles that fit in on-chip BRAM. Tile size is determined by available BRAM and the array dimensions. For SEDA's 8×8 array, tiles are naturally 8×8.
- **DSP block utilization**: INT8 MAC maps naturally to 18×18 DSP blocks available on most FPGAs. Two INT8 multiplies can share a single 18×18 DSP via bit-packing, but this adds complexity.
- **Memory bandwidth**: Off-chip memory bandwidth is typically the bottleneck for FPGA DNN accelerators. SEDA's HyperRAM (PSRAM) will be a bottleneck; caches help mitigate this.

**SEDA Design Implications**:
- Confirms INT8 is the right precision for SEDA's MNIST workload — negligible accuracy loss with 4× memory reduction over FP32.
- Tiling strategy for 8×8 array: Conv1 (3×3 kernel) maps directly to 8×8 tiles with some padding. FC layers use standard tiled GEMM.
- DSP block sharing (2 INT8 muls per DSP) could solve SEDA's DSP budget issue (need 49, have 48) without resorting to LUT-based M-extension multiplication.
- HyperRAM bandwidth will be a bottleneck — double-buffered tiles are essential to overlap data loading with computation.

### 5.2 FILM-QNN: Mixed-Precision FPGA Acceleration
**Paper**: Li et al., "FILM-QNN: Efficient FPGA Acceleration of DNNs with Intra-Layer Mixed-Precision Quantization," FPGA 2022 (79 citations)

**Key Technical Details**:
- **DSP packing**: Multiple low-precision multiplications packed into a single DSP block. For 4-bit weights: 4 multiplications per DSP. For 8-bit: 1 multiplication per DSP (native mapping).
- **Weight reordering**: Weights are reordered in memory to match the PE array access pattern, eliminating address calculation overhead at runtime.
- **Data packing**: Input activations are packed into wider words for efficient BRAM access. For INT8: 4 activations per 32-bit word.
- **Resource model**: A mathematical model balances LUT/DSP/BRAM allocation. The model determines the optimal mix of LUT-based and DSP-based computation for a given FPGA device.
- **Results on ZCU102**: ResNet-18 at 214.8 FPS, MobileNet-V2 at 537.9 FPS with mixed 4-bit/8-bit precision.

**SEDA Design Implications**:
- Data packing for INT8 (4 activations per 32-bit word) should be used in SEDA's memory interface to maximize BRAM bandwidth utilization.
- Weight reordering should be done offline (during firmware compilation) to simplify the hardware datapath.
- The resource balancing model concept is relevant for SEDA's Tang Nano 20K fit analysis — balancing DSP/LUT/BRAM usage.

---

## 6. IMPLEMENTATION DESIGN GUIDELINES (Synthesized from All Papers)

### 6.1 Systolic Array Design Decisions
Based on the literature, SEDA should:
1. **Use Weight Stationary (WS) dataflow** — best for edge inference with small batch sizes (Gemmini, Raja findings).
2. **8×8 array size is appropriate** — Gemmini shows 16×16 for edge is optimal at higher resource budgets; 8×8 is the right size for Tang Nano 20K's constraints.
3. **Pipeline registers between tile groups** — Consider splitting 8×8 into tiles (e.g., 4×2×4) with pipeline registers for timing closure (Gemmini's two-level hierarchy).
4. **Double-buffered input tiles** — Essential for overlapping data loading with computation (SPOTS, Gemmini).
5. **Output Stationary accumulation** — Partial sums stay in PE accumulators (32-bit) while weights and activations flow through.

### 6.2 Zero-Skip Logic Design
Based on the literature, SEDA's Gate 1 should:
1. **OR-reduce both inputs** — Check if either A or B is zero (8-bit OR-reduce = 1 LUT4 per 4 bits = 2 LUTs per input = ~4 LUTs, not 8).
2. **Gate the MAC clock/enable** — When skip is detected, disable the DSP block's clock enable to save dynamic power (zero gating approach from Zhu et al.).
3. **Propagate previous accumulator value** — On skip, the accumulator retains its previous value (no zero-write needed).
4. **Track skip count per PE** — Saturating counter for performance monitoring.

### 6.3 Change Detection Design
Based on the literature, SEDA's Gate 2 should:
1. **XOR previous and current input** — If XOR result is zero, input unchanged.
2. **Shadow register per PE** — Stores previous A input (8 bits). Updated only when computation actually fires.
3. **Combine with zero-detection** — Change detection only applies to non-zero inputs (zero inputs are already caught by Gate 1).
4. **Clear shadow registers on new tile** — When mm.load loads a new tile, shadow registers should be cleared to prevent false change-skip on the first cycle.

### 6.4 Spike Threshold Design
Based on the literature, SEDA's Gate 3 should:
1. **Magnitude comparison** — Compare |A| against threshold (unsigned comparison after absolute value).
2. **Programmable threshold via CSR** — The mm.sparse instruction writes the threshold value to a control register that fans out to all PEs.
3. **Threshold = 0 disables spike gating** — Setting threshold to 0 means all non-zero values pass (effectively disables Gate 3).
4. **8-bit unsigned threshold** — Range 0-255, applied to the absolute value of the 8-bit signed input.

### 6.5 Custom ISA Extension Implementation
Based on the literature, SEDA's mm.* instructions should:
1. **Use custom-0 opcode (0001011)** — Standard RISC-V reserved opcode space for custom extensions.
2. **funct3 field for instruction type** — 3-bit field encodes which mm.* instruction (load/start/wait/store/sparse).
3. **Decoder extension is minimal** — Add a case for opcode 0001011 in the existing decoder, extract funct3, generate appropriate control signals.
4. **mm.wait can poll via AXI** — Rather than true pipeline stall, mm.wait can poll the accelerator's busy status register via AXI and spin-wait. Simpler than modifying pipeline hazard logic.
5. **mm.sparse writes two CSRs** — sparse_enable (1 bit) and spike_threshold (8 bits) packed into a single AXI write. Returns previous skip_count in rd.

### 6.6 Verification Strategy
Based on the literature (Gemmini's cocotb-based verification, Eyeriss v2's systematic testing):
1. **NumPy golden model** — For every test, compute expected output using NumPy's matmul with the same INT8 data. Compare bit-exact.
2. **Sparse vs. Dense equivalence** — Run identical inputs with SEDA on/off. Results must be bit-exact. Only skip_count should differ.
3. **Coverage bins for sparsity** — Test at 0%, 25%, 50%, 75%, 90%, 100% sparsity levels. Each level must produce correct results.
4. **Edge cases**: All-zero matrix, all-max matrix (127), alternating zero/non-zero, single non-zero element, threshold exactly at input value.
5. **AXI4 protocol compliance** — Verify burst transfers, VALID/READY handshaking, response ordering.

### 6.7 MNIST CNN Mapping
Based on the literature (INT8 quantization surveys, tiled matmul approaches):
1. **Quantization**: Post-training quantization FP32 → INT8 using PyTorch's quantization toolkit. Scale factors per-layer.
2. **Conv-to-GEMM**: Use im2col transformation in firmware to convert convolutions to matrix multiplications that the 8×8 systolic array can process.
3. **Tiling**: For Conv1 (28×28×1 → 26×26×8, 3×3 kernel): The 3×3×1 kernel fits in one PE row. 8 output channels = 8 columns of the weight matrix. Tile the spatial dimensions (26×26) into 8×8 blocks.
4. **Expected skip rates**: Conv1+ReLU1 → ~65% zeros in input to Conv2. Conv2+ReLU2 → ~70% zeros in input to FC1. Overall: ~60% MACs skipped.
5. **Expected accuracy**: INT8 MNIST should achieve ≥98% (literature consistently shows <1% degradation for INT8 on MNIST).

---

## 7. KEY PAPERS QUICK REFERENCE

| # | Paper | Year | Citations | Key Relevance to SEDA |
|---|-------|------|-----------|----------------------|
| 1 | Mishra et al. "Accelerating Sparse DNNs" (NVIDIA) | 2021 | 280 | 2:4 sparsity pattern, Sparse Tensor Core design |
| 2 | Zhu et al. "Efficient HW Accel for Structured Sparse CNNs" | 2020 | 111 | Sparsewise dataflow, zero gating on FPGA |
| 3 | Liu et al. "Zero-Activation-Skipping" | 2021 | 5 | Post-ReLU activation sparsity exploitation, 7.29× speedup |
| 4 | Qureshi et al. "Sparse-PE" | 2021 | 8 | Binary mask sparse PE design, two-sided sparsity |
| 5 | Soltaniyeh et al. "SPOTS" | 2022 | 27 | Systolic array + sparsity combined, Im2Col+GEMM |
| 6 | Genç et al. "Gemmini" (Berkeley) | 2019 | 73 | Open-source RISC-V systolic array, ISA interface, fabricated |
| 7 | Qin et al. "SIGMA" | 2020 | 444 | Flexible sparse GEMM, FAN reduction tree |
| 8 | Chen et al. "Eyeriss v2" (MIT) | 2019 | — | Sparse PE, hierarchical mesh NoC, RS+ dataflow |
| 9 | Raja "Systolic Array Data Flows" | 2024 | 3 | WS vs IS vs OS dataflow comparison |
| 10 | Roy et al. "Spike-Based ML with Neuromorphic" (Nature) | 2019 | 1751 | Spike encoding, event-driven computation theory |
| 11 | Davies et al. "Loihi" (Intel) | 2021 | 502 | Neuromorphic processor, spike threshold, event-driven |
| 12 | Zhou et al. "Event-Driven Vision Sensors" (Nature Elec.) | 2023 | 150 | Change-only sensing, temporal redundancy elimination |
| 13 | Bouvier et al. "SNN Hardware Survey" | 2019 | 128 | Neuron model hardware costs, threshold detector design |
| 14 | Sabih et al. "RISC-V Extensions for Sparse DNNs" | 2024 | 5 | Custom ISA for sparse DNN on FPGA, 3-5× speedup |
| 15 | Armeniakos et al. "MaRVIn" | 2025 | 0 | Mixed-precision RISC-V ISA extensions, 17.6× speedup |
| 16 | Fritzmann et al. "RISQ-V" | 2020 | 144 | Tightly coupled RISC-V accelerator, 29 custom instructions |
| 17 | Wu et al. "FPGA DNN Acceleration Survey" | 2021 | 71 | INT8 quantization, tiling, DSP mapping strategies |
| 18 | Li et al. "FILM-QNN" | 2022 | 79 | DSP packing, weight reordering, resource balancing |
| 19 | Rathi et al. "Neuromorphic Computing Survey" (ACM) | 2022 | 173 | SNN algorithms to hardware, full-stack optimization |
| 20 | VerSA "Versatile Systolic Array" | 2024 | 3 | Early termination in sparse systolic arrays |

---

## 8. ARXIV LINKS FOR FULL PAPER ACCESS

1. NVIDIA Sparse DNNs: https://arxiv.org/abs/2104.08378
2. Gemmini: https://arxiv.org/abs/1911.09925
3. SIGMA: https://arxiv.org/abs/2002.04540 (HPCA 2020 version)
4. Eyeriss v2: https://arxiv.org/abs/1807.07928
5. Loihi Survey: https://doi.org/10.1109/JPROC.2021.3067593
6. Neuromorphic Nature: https://doi.org/10.1038/s41586-019-1677-2
7. Event-Driven Sensors: https://doi.org/10.1038/s41928-023-01055-2
8. RISQ-V: https://eprint.iacr.org/2020/1045
9. MaRVIn: https://arxiv.org/abs/2502.07826
10. SPOTS: https://doi.org/10.1145/3madhya3547524

---

*Document generated April 2026. Feed this entire document as context to Claude Code when developing SEDA RTL, verification testbenches, or firmware.*
