
all: $(PROJ).rpt $(PROJ).bin

%.blif: %.v $(ADD_SRC) $(ADD_DEPS)
	$(PODMAN) yosys -ql $*.log $(if $(USE_ARACHNEPNR),-DUSE_ARACHNEPNR) -p 'synth_ice40 -blif $@' $< $(ADD_SRC)

%.json: %.v $(ADD_SRC) $(ADD_DEPS)
	$(PODMAN) yosys -ql $*.log $(if $(USE_ARACHNEPNR),-DUSE_ARACHNEPNR) -p 'synth_ice40 -json $@' $< $(ADD_SRC)

ifeq ($(USE_ARACHNEPNR),)
%.asc: $(PIN_DEF) %.json
	$(PODMAN) nextpnr-ice40 --$(DEVICE) $(if $(PACKAGE),--package $(PACKAGE)) $(if $(FREQ),--freq $(FREQ)) --json $(filter-out $<,$^) --pcf $< --asc $@
else
%.asc: $(PIN_DEF) %.blif
	$(PODMAN) arachne-pnr -d $(subst up,,$(subst hx,,$(subst lp,,$(DEVICE)))) $(if $(PACKAGE),-P $(PACKAGE)) -o $@ -p $^
endif


%.bin: %.asc
	$(PODMAN) icepack $< $@

%.rpt: %.asc
	$(PODMAN) icetime $(if $(FREQ),-c $(FREQ)) -d $(DEVICE) -mtr $@ $<

%_tb: %_tb.v %.v
	$(PODMAN) iverilog -o $@ $^

%_tb.vcd: %_tb
	$(PODMAN) vvp -N $< +vcd=$@

%_syn.v: %.blif
	$(PODMAN) yosys -p 'read_blif -wideports $^; write_verilog $@'

%_syntb: %_tb.v %_syn.v
	$(PODMAN) iverilog -o $@ $^ `yosys-config --datdir/ice40/cells_sim.v`

%_syntb.vcd: %_syntb
	$(PODMAN) vvp -N $< +vcd=$@

test: $(TEST_SRC) $(ADD_SRC)
	$(PODMAN) sh -c "iverilog -g2012 -o test.vvp $(TEST_SRC) $(ADD_SRC) && vvp test.vvp"

waveforms: test
	$(PODMAN) python3 vcd2svg.py test_lcd.vcd --output-dir waveforms

schematic: $(ADD_SRC)
	@mkdir -p schematic
	$(PODMAN) sh -c "\
		yosys -p 'read_verilog -sv $(ADD_SRC); proc; opt; clean; \
			show -format dot -prefix schematic/lcd_rtl -colors 1 -notitle' && \
		dot -Tsvg schematic/lcd_rtl.dot -o schematic/lcd_rtl.svg && \
		dot -Tpdf schematic/lcd_rtl.dot -o schematic/lcd_rtl.pdf"

prog: $(PROJ).bin
	$(PODMAN_DEV) icesprog $<

sudo-prog: $(PROJ).bin
	@echo 'Executing prog as root!!!'
	sudo iceprog $<

clean:
	rm -f $(PROJ).blif $(PROJ).asc $(PROJ).rpt $(PROJ).bin $(PROJ).json $(PROJ).log $(ADD_CLEAN) test.vvp test_lcd.vcd test_lcd.vvp
	rm -rf waveforms schematic

.SECONDARY:
.PHONY: all prog test waveforms schematic clean
