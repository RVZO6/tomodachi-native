# 合成資料與獨立目錄上的原生匯入測試。
# Native import tests on synthetic data and isolated directories.
.DEFAULT_GOAL := run
B=build
SRC=../Sources
CFLAGS=-O1 -g -Wall -Wextra -Wno-deprecated-declarations
$(B):
	mkdir -p $@
$(B)/t_mii_codec: t_mii_codec.c $(SRC)/dm_mii_codec.c $(SRC)/dm_mii_codec.h $(SRC)/MiiZstd.c ../../third_party/zstd/zstddeclib.c | $(B)
	clang $(CFLAGS) -fsanitize=address,undefined -fno-omit-frame-pointer t_mii_codec.c $(SRC)/dm_mii_codec.c $(SRC)/MiiZstd.c -o $@
$(B)/mii_store_cli: mii_store_cli.m $(SRC)/DuoMii.m $(SRC)/DuoSave.m $(SRC)/dm_mii_codec.c $(SRC)/MiiZstd.c $(SRC)/dm_mii_codec.h $(SRC)/duo_mii.h $(SRC)/duo_save_store.h ../../third_party/zstd/zstddeclib.c | $(B)
	clang $(CFLAGS) -fobjc-arc -DDM_MII_TEST=1 mii_store_cli.m $(SRC)/DuoMii.m $(SRC)/DuoSave.m $(SRC)/dm_mii_codec.c $(SRC)/MiiZstd.c -framework Foundation -o $@
.PHONY: run
run: $(B)/t_mii_codec $(B)/mii_store_cli
	$(B)/t_mii_codec
	python3 test_mii_store.py
