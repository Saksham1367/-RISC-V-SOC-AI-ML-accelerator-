module cocotb_iverilog_dump();
initial begin
    string dumpfile_path;    if ($value$plusargs("dumpfile_path=%s", dumpfile_path)) begin
        $dumpfile(dumpfile_path);
    end else begin
        $dumpfile("C:\\Users\\saksh\\Desktop\\riscv-soc-ai-ml-accelerator\\sim\\accelerator_top\\accelerator_top.fst");
    end
    $dumpvars(0, accelerator_top);
end
endmodule
