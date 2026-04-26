module cocotb_iverilog_dump();
initial begin
    string dumpfile_path;    if ($value$plusargs("dumpfile_path=%s", dumpfile_path)) begin
        $dumpfile(dumpfile_path);
    end else begin
        $dumpfile("C:\\Users\\saksh\\Desktop\\riscv-soc-ai-ml-accelerator\\sim\\sa_buffer\\sa_buffer.fst");
    end
    $dumpvars(0, sa_buffer);
end
endmodule
