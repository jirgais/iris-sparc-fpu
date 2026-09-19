.PHONY: ise
ise:
	xst -ifn irisfpu.xst

quartus:
	quartus_map  --import_settings_files=on  --export_settings_files=off irisfpu -c irisfpu
	quartus_fit irisfpu -c irisfpu
	quartus_asm irisfpu -c irisfpu
	quartus_sta irisfpu -c irisfpu
 
clean:
	-rm -rf xst irisfpu.lso irisfpu.ngc irisfpu.srp _xmsgs xst db \
  c5_pin_model_dump.txt db incremental_db irisfpu.asm.rpt irisfpu.done \
  irisfpu.fit.summary irisfpu.flow.rpt irisfpu.jdi irisfpu.map.rpt \
  irisfpu.map.summary irisfpu.sld irisfpu.sof irisfpu.sta.rpt \
  irisfpu.sta.summary irisfpu_xst.xrpt irisfpu.fit.rpt irisfpu.pin
