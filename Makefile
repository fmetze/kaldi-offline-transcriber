SHELL := /bin/bash

# Use this file to override various settings
-include Makefile.options

# Set to 'yes' if you want to do speaker ID for trs files
# Assumes you have models for speaker ID
FAKE_SEGMENTATION?=no
DO_SPEAKER_ID?=no
SID_THRESHOLD?=25

# Do we want to do 1-pass decoding using nnet2 models instead of 3-pass decoding?
# Should be about 3 times faster with 10% more errors
DO_NNET2_ONLINE?=no

# Pitch models (newer eesen)?
USE_PITCH?=false

# Where is Kaldi root directory?
KALDI_ROOT?=/home/speech/tools/kaldi-trunk

# Location of the Java binary
JAVA_BIN?=/usr/bin/java

# How many processes to use for one transcription task
njobs ?= 1

# How many threads to use in each process
nthreads ?= 1

PATH := utils:$(KALDI_ROOT)/src/decoderbin:$(KALDI_ROOT)/src/netbin:$(KALDI_ROOT)/src/featbin:$(KALDI_ROOT)/src/fstbin:$(KALDI_ROOT)/tools/openfst/bin:$(PATH)

export train_cmd=run.pl
export decode_cmd=run.pl
export cuda_cmd=run.pl
export mkgraph_cmd=run.pl

# Main language model (should be slightly pruned), used for rescoring
LM ?=language_model/pruned.vestlused-dev.splitw2.arpa.gz

# More aggressively pruned LM, used in decoding
PRUNED_LM ?=language_model/pruned6.vestlused-dev.splitw2.arpa.gz

COMPOUNDER_LM ?=language_model/compounder-pruned.vestlused-dev.splitw.arpa.gz

# Vocabulary in dict format (no pronouncation probs for now)
VOCAB?=language_model/vestlused-dev.splitw2.dict

LM_SCALE?=6

# Find out where this Makefile is located (this is not really needed)
where-am-i = $(lastword $(MAKEFILE_LIST))
THIS_DIR := $(shell dirname $(call where-am-i))

ifeq ($(DO_NNET2_ONLINE),yes)
  FINAL_PASS=nnet2_online_ivector_pruned_rescored_main
else
ifeq ($(DO_NNET2_ONLINE),dnnfbank)
  FINAL_PASS=dnn_fbank
else
  #FINAL_PASS=nnet5c1_pruned_rescored_main
  #FINAL_PASS=tri4a
  FINAL_PASS=eesen8
endif
endif

LD_LIBRARY_PATH=$(KALDI_ROOT)/tools/openfst/lib

.SECONDARY:
.DELETE_ON_ERROR:

export

# Call this (once) before using the system
.init: .kaldi .lang

.kaldi:
	rm -f steps utils sid
	ln -s $(KALDI_ROOT)/asr_egs/wsj/steps
	ln -s $(KALDI_ROOT)/asr_egs/wsj/utils
	ln -s $(KALDI_ROOT)/egs/sre08/v1/sid
	mkdir -m 777 -p src-audio Log
	mkdir        -p build/audio/segmented build/audio/base build/diarization build/trans build/sid build/output
	ln -s /home/docker/box/eesen-data .

.lang: build/fst/data/prunedlm build/fst/tri3b/graph_prunedlm  build/fst/nnet2_online_ivector/graph_prunedlm build/fst/data/largelm build/fst/data/compounderlm


# Convert dict and LM to FST format
build/fst/data/dict build/fst/data/prunedlm: $(PRUNED_LM) $(VOCAB)
	rm -rf build/fst/data/dict build/fst/data/prunedlm
	mkdir -p build/fst/data/dict build/fst/data/prunedlm
	cp -r $(THIS_DIR)/kaldi-data/dict/* build/fst/data/dict
	rm -f build/fst/data/dict/lexicon.txt build/fst/data/dict/lexiconp.txt
	cat models/etc/filler16k.dict | egrep -v "^<.?s>"   > build/fst/data/dict/lexicon.txt
	cat $(VOCAB) | perl -npe 's/\(\d\)(\s)/\1/' >> build/fst/data/dict/lexicon.txt
	utils/prepare_lang.sh build/fst/data/dict "++garbage++" build/fst/data/dict/tmp build/fst/data/prunedlm
	gunzip -c $(PRUNED_LM) | \
		grep -v '<s> <s>' | \
		grep -v '</s> <s>' | \
		grep -v '</s> </s>' | \
		arpa2fst - | fstprint | \
		utils/eps2disambig.pl | utils/s2eps.pl | fstcompile --isymbols=build/fst/data/prunedlm/words.txt \
			--osymbols=build/fst/data/prunedlm/words.txt  --keep_isymbols=false --keep_osymbols=false | \
		 fstrmepsilon > build/fst/data/prunedlm/G.fst
	fstisstochastic build/fst/data/prunedlm/G.fst || echo "Warning: LM not stochastic"

build/fst/data/largelm: build/fst/data/prunedlm $(LM)
	rm -rf $@
	mkdir -p $@
	utils/build_const_arpa_lm.sh \
		$(LM) build/fst/data/prunedlm $@

build/fst/data/compounderlm: $(COMPOUNDER_LM) $(VOCAB)
	rm -rf $@
	mkdir -p $@
	cat $(VOCAB) | perl -npe 's/(\(\d\))?\s.+//' | uniq | python scripts/make-compounder-symbols.py > $@/words.txt
	zcat $(COMPOUNDER_LM) | \
		grep -v '<s> <s>' | \
		grep -v '</s> <s>' | \
		grep -v '</s> </s>' | \
		arpa2fst  - | fstprint | \
		utils/s2eps.pl | fstcompile --isymbols=$@/words.txt --osymbols=$@/words.txt > $@/G.fst 

# override some paths in nnet2 conf files
build/fst/nnet2_online_ivector/final.mdl:
	rm -rf `dirname $@`
	mkdir -p `dirname $@`
	cp -r $(THIS_DIR)/kaldi-data/nnet2_online_ivector/* `dirname $@`
	perl -i -npe 's/=.*nnet2_online_ivector([_-\w]*)online/=build\/fst\/nnet2_online_ivector/' build/fst/nnet2_online_ivector/conf/*.conf

build/fst/%/final.mdl:
	rm -rf `dirname $@`
	mkdir -p `dirname $@`
	cp -r $(THIS_DIR)/kaldi-data/$*/* `dirname $@`

build/fst/%/graph_prunedlm: build/fst/data/prunedlm build/fst/%/final.mdl
	rm -rf $@
	utils/mkgraph.sh build/fst/data/prunedlm build/fst/$* $@

build/audio/base/%.wav: src-audio/%.wav
	mkdir -p `dirname $@`
	sox $^ -c 1 -b 16 build/audio/base/$*.wav rate -v 8k || ffmpeg -i $^ -f sox - | sox -t sox - -c 1 -b 16 -r 8k $@

build/audio/base/%.wav: src-audio/%.wmv
	mkdir -p `dirname $@`
	ffmpeg -i $^ -f sox - | sox -t sox - -c 1 -b 16 -r 8k $@

build/audio/base/%.wav: src-audio/%.mp4
	mkdir -p `dirname $@`
	ffmpeg -i $^ -f sox - | sox -t sox - -c 1 -b 16 -r 8k $@

ifeq "1" "$(CHANNEL_NO)"
build/audio/base/%.wav: src-audio/%.mp3
	mkdir -p `dirname $@`
	sox $^ -c 1 build/audio/base/$*.wav rate -v 8k remix 1
else ifeq "2" "$(CHANNEL_NO)"
build/audio/base/%.wav: src-audio/%.mp3
	mkdir -p `dirname $@`
	sox $^ -c 1 build/audio/base/$*.wav rate -v 8k remix 2
else
build/audio/base/%.wav: src-audio/%.mp3
	mkdir -p `dirname $@`
	sox $^ -c 1 build/audio/base/$*.wav rate -v 8k
endif

build/audio/base/%.wav: src-audio/%.ogg
	mkdir -p `dirname $@`
	sox $^ -c 1 build/audio/base/$*.wav rate -v 8k

build/audio/base/%.wav: src-audio/%.mp2
	mkdir -p `dirname $@`
	sox $^ -c 1 build/audio/base/$*.wav rate -v 8k

build/audio/base/%.wav: src-audio/%.m4a
	mkdir -p `dirname $@`
	ffmpeg -i $^ -f sox - | sox -t sox - -c 1 -b 16 $@ rate -v 8k

build/audio/base/%.wav: src-audio/%.flac
	mkdir -p `dirname $@`
	sox $^ -c 1 build/audio/base/$*.wav rate -v 8k

build/audio/base/%.wav: src-audio/%.amr
	mkdir -p `dirname $@`
	amrnb-decoder $^ $@.tmp.raw
	sox -s -b 16 -c 1 -r 8000 $@.tmp.raw -c 1 build/audio/base/$*.wav rate -v 8k
	rm $@.tmp.raw

build/audio/base/%.wav: src-audio/%.mpg
	mkdir -p `dirname $@`
	ffmpeg -i $^ -f sox - | sox -t sox - -c 1 -b 16 build/audio/base/$*.wav rate -v 8k

build/audio/base/%.wav: src-audio/%.sph
	mkdir -p `dirname $@`
	sox $^ -c 1 -b 16 build/audio/base/$*.wav rate -v 8k

# Speaker diarization
build/diarization/%/show.seg: build/audio/base/%.wav
	rm -rf `dirname $@`
	mkdir -p `dirname $@`
ifeq ($(FAKE_SEGMENTATION),always)
	echo $* | awk -v a=`soxi -s $^` -v b=`soxi -r $^` ' { print $$0,1,0,int(100*a/b),"M","T","U","S0" } ' > $@;
else ifeq ($(FAKE_SEGMENTATION),yes)
	echo $* | awk -v a=`soxi -s $^` -v b=`soxi -r $^` ' { print int(100*a/b) } ' > $@;
	if [ `cat $@` -gt 1000 ]; then \
		echo THIS IS USING SEGMENTATION; cat $@; \
		echo "$* 1 0 1000000000 U U U 1" >  `dirname $@`/show.uem.seg; \
		./scripts/diarization.sh $^ `dirname $@`/show.uem.seg; \
	else \
		echo THIS IS NOT USING SEGMENTATION; \
		echo $* | awk -v a=`soxi -s $^` -v b=`soxi -r $^` ' { print $$0,1,0,int(100*a/b),"M","T","U","S0" } ' > $@; \
	fi
else
	echo "$* 1 0 1000000000 U U U 1" >  `dirname $@`/show.uem.seg;
	./scripts/diarization.sh $^ `dirname $@`/show.uem.seg;
endif

build/audio/segmented/%: build/diarization/%/show.seg
	rm -rf $@
	mkdir -p $@
	cat $^ | cut -f 3,4,8 -d " " | \
	while read LINE ; do \
		start=`echo $$LINE | cut -f 1 -d " " | perl -npe '$$_=$$_/100.0'`; \
		len=`echo $$LINE | cut -f 2 -d " " | perl -npe '$$_=$$_/100.0'`; \
		sp_id=`echo $$LINE | cut -f 3 -d " "`; \
		timeformatted=`echo "$$start $$len" | perl -ne '@t=split(); $$start=$$t[0]; $$len=$$t[1]; $$end=$$start+$$len; printf("%08.3f-%08.3f\n", $$start,$$end);'` ; \
		sox build/audio/base/$*.wav --norm $@/$*_$${timeformatted}_$${sp_id}.wav trim $$start $$len ; \
	done

build/trans/%/wav.scp: build/audio/segmented/%
	mkdir -p `dirname $@`
	/bin/ls $</*.wav  | \
		perl -npe 'chomp; $$orig=$$_; s/.*\/(.*)_(\d+\.\d+-\d+\.\d+)_(S\d+)\.wav/\1-\3---\2/; $$_=$$_ .  " $$orig\n";' | LC_ALL=C sort > $@

build/trans/%/utt2spk: build/trans/%/wav.scp
	cat $^ | perl -npe 's/\s+.*//; s/((.*)---.*)/\1 \2/' > $@

build/trans/%/spk2utt: build/trans/%/utt2spk
	utils/utt2spk_to_spk2utt.pl $^ > $@


# MFCC calculation
build/trans/%/mfcc: build/trans/%/spk2utt
	rm -rf $@
	steps/make_mfcc.sh --mfcc-config conf/mfcc_8kHz.conf --cmd "$$train_cmd" --nj $(njobs) \
		build/trans/$* build/trans/$*/exp/make_mfcc $@ || exit 1
	steps/compute_cmvn_stats.sh build/trans/$* build/trans/$*/exp/make_mfcc $@ || exit 1

# FBANK calculation
build/trans/%/fbank: build/trans/%/spk2utt
	rm -rf $@
ifeq ($(USE_PITCH),yes)
	steps/make_fbank_pitch.sh --fbank-config conf/fbank_8kHz.conf --cmd "$$train_cmd" --nj $(njobs) \
		build/trans/$* build/trans/$*/exp/make_fbank $@ || exit 1
else
	steps/make_fbank.sh --fbank-config conf/fbank_8kHz.conf --cmd "$$train_cmd" --nj $(njobs) \
		build/trans/$* build/trans/$*/exp/make_fbank $@ || exit 1
endif
	steps/compute_cmvn_stats.sh build/trans/$* build/trans/$*/exp/make_fbank $@ || exit 1


### First, decode using tri4a (LDA+MLLT+SAT+MMI trained triphones)
### build/fst/tri3b/graph_prunedlm
build/trans/%/tri4a/decode/log: build/fst_swbd/tri4a/final.alimdl build/fst_swbd/tri4a/final.mdl build/trans/%/mfcc
	rm -rf build/trans/$*/tri4a
	mkdir -p build/trans/$*/tri4a
	(cd build/trans/$*/tri4a; for f in ../../../fst_swbd/tri4a/*; do ln -s $$f; done)
	steps/decode_fmllr.sh --num-threads $(nthreads) --config conf/decode.conf --skip-scoring true --nj $(njobs) --cmd "$$decode_cmd" \
		--alignment-model build/fst_swbd/tri4a/final.alimdl --adapt-model build/fst_swbd/tri4a/final.mdl \
		build/fst_swbd/tri4a/graph_sw1_tg build/trans/$* `dirname $@`
	(cd build/trans/$*/tri4a; ln -s ../../../fst_swbd/tri4a/graph_sw1_tg graph)


### Alternatively, decode using tri4b (LDA+MLLT+SAT+MMI trained triphones)
### build/fst/tri3b/graph_prunedlm
build/trans/%/tri4b/decode/log: build/fst_swbd/tri4b/final.alimdl \
				build/fst_swbd/tri4b/final.mdl build/trans/%/mfcc
	rm -rf build/trans/$*/tri4b
	mkdir -p build/trans/$*/tri4b
	(cd build/trans/$*/tri4b; for f in ../../../fst_swbd/tri4b/*; do ln -s $$f; done)
	steps/decode_fmllr.sh --num-threads $(nthreads) --config conf/decode.conf \
		--skip-scoring true --nj $(njobs) --cmd "$$decode_cmd" \
		--alignment-model build/fst_swbd/tri4b/final.alimdl \
		--adapt-model build/fst_swbd/tri4b/final.mdl \
		build/fst_swbd/tri4b/graph_sw1_tg build/trans/$* `dirname $@`
	(cd build/trans/$*/tri4b; ln -s ../../../fst_swbd/tri4b/graph_sw1_tg graph)

# Now, decode using nnet AM, using speaker transforms from tri4a
build/trans/%/nnet5c1_pruned/decode/log: build/trans/%/tri3b_mmi_pruned/decode/log build/fst/nnet5c1/final.mdl
	rm -rf build/trans/$*/nnet5c1_pruned
	mkdir -p build/trans/$*/nnet5c1_pruned
	(cd build/trans/$*/nnet5c1_pruned; for f in ../../../fst/nnet5c1/*; do ln -s $$f; done)
	steps/nnet2/decode.sh --num-threads $(nthreads) --skip-scoring true --cmd "$$decode_cmd" --nj $(njobs) \
    --transform-dir build/trans/$*/tri3b_mmi_pruned/decode \
     build/fst/tri3b/graph_prunedlm build/trans/$* `dirname $@`
	(cd build/trans/$*/nnet5c1_pruned; ln -s ../../../fst/tri3b/graph_prunedlm graph)

# Rescore with a larger language model
build/trans/%/nnet5c1_pruned_rescored_main/decode/log: build/trans/%/nnet5c1_pruned/decode/log build/fst/data/largelm
	rm -rf build/trans/$*/nnet5c1_pruned_rescored_main
	mkdir -p build/trans/$*/nnet5c1_pruned_rescored_main
	(cd build/trans/$*/nnet5c1_pruned_rescored_main; for f in ../../../fst/nnet5c1/*; do ln -s $$f; done)
	steps/lmrescore_const_arpa.sh \
	  build/fst/data/prunedlm build/fst/data/largelm \
	  build/trans/$* \
	  build/trans/$*/nnet5c1_pruned/decode build/trans/$*/nnet5c1_pruned_rescored_main/decode || exit 1;
	cp -r --preserve=links build/trans/$*/nnet5c1_pruned/graph build/trans/$*/nnet5c1_pruned_rescored_main/	


### Alternatively, do 1-pass decoding using nnet2 online models
build/trans/%/nnet2_online_ivector_pruned/decode/log: build/fst/nnet2_online_ivector/final.mdl build/fst/nnet2_online_ivector/graph_prunedlm build/trans/%/spk2utt build/trans/%/mfcc
	rm -rf build/trans/$*/nnet2_online_ivector_pruned
	mkdir -p build/trans/$*/nnet2_online_ivector_pruned
	(cd build/trans/$*/nnet2_online_ivector_pruned; for f in ../../../fst/nnet2_online_ivector/*; do ln -s $$f; done)
	steps/online/nnet2/decode.sh --config conf/decode.conf --skip-scoring true --cmd "$$decode_cmd" --nj $(njobs) \
      build/fst/nnet2_online_ivector/graph_prunedlm build/trans/$* `dirname $@` || exit 1;
	(cd build/trans/$*/nnet2_online_ivector_pruned; ln -s ../../../fst/nnet2_online_ivector/graph_prunedlm graph)

# Rescore nnet2 lattices with a larger language model
build/trans/%/nnet2_online_ivector_pruned_rescored_main/decode/log: build/trans/%/nnet2_online_ivector_pruned/decode/log build/fst/data/largelm
	rm -rf build/trans/$*/nnet2_online_ivector_pruned_rescored_main
	mkdir -p build/trans/$*/nnet2_online_ivector_pruned_rescored_main
	(cd build/trans/$*/nnet2_online_ivector_pruned_rescored_main; for f in ../../../fst/nnet2_online_ivector/*; do ln -s $$f; done)
	steps/lmrescore_const_arpa.sh \
	  build/fst/data/prunedlm build/fst/data/largelm \
	  build/trans/$* \
	  build/trans/$*/nnet2_online_ivector_pruned/decode build/trans/$*/nnet2_online_ivector_pruned_rescored_main/decode || exit 1;
	cp -r --preserve=links build/trans/$*/nnet2_online_ivector_pruned/graph build/trans/$*/nnet2_online_ivector_pruned_rescored_main/	


### Use Yajie's single-pass FBank-DNN
build/trans/%/dnn_fbank/decode/log: build/trans/%/spk2utt build/trans/%/fbank
	rm -rf build/trans/$*/dnn_fbank
	mkdir -p build/trans/$*/dnn_fbank
	(cd build/trans/$*/dnn_fbank; for f in ../../../fst_swbd/dnn_fbank/*; do ln -s $$f; done)
	steps_pdnn/decode_dnn.sh --config conf/decode.conf --skip-scoring true --cmd "$$decode_cmd" --nj $(njobs) \
		build/fst_swbd/tri4b/graph_sw1_tg build/trans/$* build/fst_swbd/tri4b `dirname $@` || exit 1;
	(cd build/trans/$*/dnn_fbank; ln -s ../../../fst_swbd/dnn_fbank/graph_sw1_tg graph)


### Decode with Eesen & 8kHz models
build/trans/%/eesen8/decode/log: build/trans/%/spk2utt build/trans/%/fbank
	rm -rf build/trans/$*/eesen8 && mkdir -p build/trans/$*/eesen8
	(cd build/trans/$*/eesen8; for f in ../../../../eesen-data/train_phn_l5_c320/*; do ln -s $$f; done)
	ln -s `pwd`/eesen-data/lang_phn_sw1_fsh_tgpr `pwd`/build/trans/$*/eesen8/graph
ifeq($(USE_PITCH),yes)
	local/decode_ctc_lat.sh --cmd "$$decode_cmd" --nj $(njobs) --skip-scoring true \
		eesen-data/lang_phn_sw1_fsh_tgpr build/trans/$* `dirname $@` || exit 1;
else
	steps/decode_ctc_lat.sh --cmd "$$decode_cmd" --nj $(njobs) --skip-scoring true \
		eesen-data/lang_phn_sw1_fsh_tgpr build/trans/$* `dirname $@` || exit 1;
endif
	# steps for non-pitch&old eesen, local for pitch&new eesen

### Shared part again
%/decode/.ctm: %/decode/log
	local/get_ctm.sh --cmd "$$decode_cmd" \
		$* eesen-data/lang_phn_sw1_fsh_tgpr `dirname $@`
	local/get_ctms.sh --cmd "$$decode_cmd" \
		$* eesen-data/lang_phn_sw1_fsh_tgpr `dirname $@`
	touch -m $@

# cat build/trans/$*/decode/score_$(LM_SCALE)/`dirname $*`.ctm  | perl -npe 's/(.*)-(S\d+)---(\S+)/\1_\3_\2/' > $@
build/trans/%.segmented.splitw2.ctm: build/trans/%/decode/.ctm
	cat build/trans/$*/decode/score_$(LM_SCALE)/`dirname $*`.ctm | perl -npe 's/(.*)-(S\d+)---(\S+)/\1_\3_\2/' > $@

# build/fst/data/compounderlm
# scripts/compound-ctm.py "scripts/compounder.py build/fst/data/compounderlm/G.fst build/fst/data/compounderlm/words.txt" < $*.splitw2.ctm > $@
%.with-compounds.ctm: %.splitw2.ctm
	cat $*.splitw2.ctm > $@

# cat $^ | grep -v "++" |  grep -v "\[sil\]" | grep -v -e " $$" | perl -npe 's/\+//g' > $@
%.segmented.ctm: %.segmented.with-compounds.ctm
ifeq "combine" "$(DO_FILTER)"
	cat $^ | ./local/dofilter.sh -n > $@
else
	cat $^ > $@
endif

%.ctm: %.segmented.ctm
	cat $^ | python scripts/unsegment-ctm.py | LC_ALL=C sort -k 1,1 -k 3,3n -k 4,4n > $@

%.with-compounds.ctm: %.segmented.with-compounds.ctm
	cat $^ | python scripts/unsegment-ctm.py | LC_ALL=C sort -k 1,1 -k 3,3n -k 4,4n > $@

ifeq "yes" "$(DO_FILTER)"
%.hyp: %.segmented.ctm
	cat $^ | ./local/dofilter.sh | python scripts/segmented-ctm-to-hyp.py  > $@
else
%.hyp: %.segmented.ctm
	cat $^ | python scripts/segmented-ctm-to-hyp.py > $@
endif

ifeq "yes" "$(DO_SPEAKER_ID)"
build/trans/%/$(FINAL_PASS).trs: build/trans/%/$(FINAL_PASS).hyp build/sid/%/sid-result.txt
	cat build/trans/$*/$(FINAL_PASS).hyp | python scripts/hyp2trs.py --sid build/sid/$*/sid-result.txt > $@
else
build/trans/%/$(FINAL_PASS).trs: build/trans/%/$(FINAL_PASS).hyp
	cat $^ | python scripts/hyp2trs.py > $@
endif

%.sbv: %.hyp
	cat $^ | python scripts/hyp2sbv.py > $@

%.txt: %.hyp
	cat $^  | perl -npe 'use locale; s/ \(\S+\)/\./; $$_= ucfirst();' > $@

build/output/%.trs: build/trans/%/$(FINAL_PASS).trs	
	mkdir -p `dirname $@`
	cp $^ $@

build/output/%.ctm: build/trans/%/$(FINAL_PASS).ctm 
	mkdir -p `dirname $@`
	cp $^ $@

build/output/%.txt: build/trans/%/$(FINAL_PASS).txt
	mkdir -p `dirname $@`
	cp $^ $@

build/output/%.with-compounds.ctm: build/trans/%/$(FINAL_PASS).with-compounds.ctm
	mkdir -p `dirname $@`
	cp $^ $@

build/output/%.sbv: build/trans/%/$(FINAL_PASS).sbv
	mkdir -p `dirname $@`
	cp $^ $@

### Speaker ID stuff

# MFCC for Speaker ID, since the features for MFCC are different from speech recognition
build/sid/%/wav.scp: build/trans/%/wav.scp
	mkdir -p `dirname $@`
	ln $^ $@

build/sid/%/utt2spk : build/trans/%/utt2spk
	mkdir -p `dirname $@`
	ln $^ $@

build/sid/%/spk2utt : build/trans/%/spk2utt
	mkdir -p `dirname $@`
	ln $^ $@

build/sid/%/mfcc: build/sid/%/wav.scp build/sid/%/utt2spk build/sid/%/spk2utt
	rm -rf $@
	rm -f build/sid/$*/vad.scp
	steps/make_mfcc.sh --mfcc-config conf/mfcc_sid_8kHz.conf --cmd "$$train_cmd" --nj $(njobs) \
		build/sid/$* build/sid/$*/exp/make_mfcc $@ || exit 1
	steps/compute_cmvn_stats.sh build/sid/$* build/sid/$*/exp/make_mfcc $@ || exit 1
	sid/compute_vad_decision.sh --nj $(njobs) --cmd "$$decode_cmd" \
		build/sid/$* build/sid/$*/exp/make_vad $@  || exit 1

# i-vectors for each speaker in our audio file
build/sid/%/ivectors: build/sid/%/mfcc
	sid/extract_ivectors.sh --cmd "$$decode_cmd" --nj $(njobs) \
		$(THIS_DIR)/kaldi-data/extractor_2048_top500 build/sid/$* $@

# a cross product of train and test speakers
build/sid/%/sid-trials.txt: build/sid/%/ivectors
	cut -f 1 -d " " $(THIS_DIR)/kaldi-data/ivectors_train_top500/spk_ivector.scp | \
	while read a; do \
		cut -f 1 -d " " build/sid/$*/ivectors/spk_ivector.scp | \
		while read b; do \
			echo "$$a $$b"; \
		done ; \
	done > $@

# similarity scores
build/sid/%/sid-scores.txt: build/sid/%/sid-trials.txt
	ivector-plda-scoring \
		"ivector-copy-plda --smoothing=0.1 $(THIS_DIR)/kaldi-data/ivectors_train_top500/plda - |" \
		"ark:ivector-subtract-global-mean scp:$(THIS_DIR)/kaldi-data/ivectors_train_top500/spk_ivector.scp ark:- |" \
		"ark:ivector-subtract-global-mean scp:build/sid/$*/ivectors/spk_ivector.scp ark:- |" \
   build/sid/$*/sid-trials.txt $@

# pick speakers above the threshold
build/sid/%/sid-result.txt: build/sid/%/sid-scores.txt
	cat build/sid/$*/sid-scores.txt | sort -u -k 2,2  -k 3,3nr | sort -u -k2,2 | \
	awk 'int($$3)>=$(SID_THRESHOLD)' | perl -npe 's/(\S+) \S+-(S\d+) \S+/\2 \1/; s/-/ /g' | \
	LC_ALL=C sort -k 2 | LC_ALL=C join -1 2 - $(THIS_DIR)/kaldi-data/ivectors_train_top500/speaker2names.txt | cut -f 2- -d " " > $@


### Scoring stuff (not currently in use)

# A 'shortcut' for a whole corpus including scoring
#   (cleaning has to be done individually)
aspect = 2212c91af61c25ec1a79f254697b883e  b5f5375555484b2c00151847292ff52e \
63643477146b234b156511e7da9f641b  c7271da7bc1c4677a51a2e27f425ce2d \
645292cdadcb4bb4be0778b2f396a725  daf69b6fe30195ea815a547444f2fc23 \
75bef4d25152ebc6b5d04b4aed4ddfa5  dc88a1c28f75ce7e82ad54c0465e3d3e \
776fb88b6def8916b3bd4845381c37ee
#ctmt = $(shell mktemp -d)

build/trans/aspect/%/decode/.ctm: $(foreach file,${aspect},$(subst aspect,${file},build/trans/aspect/%/decode/.ctm))
#	cat $(foreach file,${aspect},$(subst aspect,${file},build/trans/aspect/$*.ctm)) > $$ctmt/ctm
#	echo $$ctmt
	@echo HIER
	@echo $@
	@mkdir -p $(basename $@)
	@touch $@

lzs := $(shell seq 5 7)
JOBS := $(addprefix %/job,${lzs})
#lzt := $(foreach lz,${lzs},$(subst lzp,${lz},build/trans/%/lzp.wer))
.PHONY: ${JOBS}
${JOBS}: %/decode/.ctm
	@echo THERE
	@echo $@

# $(foreach lz,${lzs},$(subst lzp,${lz},build/trans/%/lzp.wer))
#build/trans/%/wer-summary: $(foreach lz,${lzs},$(subst lzp,${lz},build/trans/%/lzp.wer))

%/wer-summary: ${JOBS}
	@echo WER
	touch $@

# WER scoring - todo: run this in parallel, see http://stackoverflow.com/questions/1490949/how-to-write-loop-in-makefile
#wers := $(addprefix wer,$(shell seq 5 20))
#.PHONY: ${wers}
#all: ${JOBS} ; echo "$@ success"
#${JOBS}: job%: ; ./a.out $*

build/trans/%/decode/wer-result:
# build/trans/%/decode/.ctm
	mkdir -p `dirname $@`
	lms=5 ; while [[ $$lms -le 20 ]] ; do \
		td=`mktemp -d`; echo "WER for lm=" $$lms >> $@; \
		cat build/trans/*/tri4b/decode/score_$${lms}/*.ctm | perl -npe 's/(.*)-(S\d+)---(\S+)/\1_\3_\2/' | python scripts/unsegment-ctm.py | LC_ALL=C sort -k 1,1 -k 3,3n -k 4,4n | awk ' { $$5=toupper($$5); print } ' | grep -v '<#S>' > $${td}/college.ctm; \
		/opt/kaldi-trunk/tools/sctk-2.4.9/bin/hubscr.pl -p /opt/kaldi-trunk/tools/sctk-2.4.9/bin -V -l english -h hub5 -g /opt/kaldi-trunk/tools/sctk-2.4.9/src/md-eval/test/en20030506.glm -r /home/docker/box/college.stm $${td}/college.ctm; \
		grep "Sum/Avg" $${td}/college.ctm.filt.sys >> $@; \
		tar -C $${td} -cjf $@.$${lms}.tar.bz2 .; rm -rf $${td}; \
		((lms = lms + 1)) ;\
	done


# Florian's scoring for RV
decode-v0/werF:
	mkdir -p `dirname $@`/score_2 `dirname $@`/score_3 `dirname $@`/score_4 `dirname $@`/score_5 `dirname $@`/score_6 `dirname $@`/score_7 `dirname $@`/score_8 `dirname $@`/score_9
	touch `dirname $@`/lat.1.gz
	cp rv.stm eesen-data/train_phn_l5_c320_V2_s20_l4/stm
	cp glm    eesen-data/train_phn_l5_c320_V2_s20_l4/glm
	./steps_eesen/score_sclite.sh eesen-data/train_phn_l5_c320_V2_s20_l4/ eesen-data/lang_phn_sw1_fsh_tgpr/ `dirname $@`
	cp build/output/*.sbv build/output/*.trs `dirname $@`/scoring
	cp build/trans/*/eesen8/decode/score_5/*.tra `dirname $@`/scoring

decode-address-v3/wer:
	mkdir -p `dirname $@`/score_2 `dirname $@`/score_3 `dirname $@`/score_4 `dirname $@`/score_5 `dirname $@`/score_6 `dirname $@`/score_7 `dirname $@`/score_8 `dirname $@`/score_9
	touch `dirname $@`/lat.1.gz
	cp rv-address.stm eesen-data/train_phn_l5_c320_V2_s20_l4/stm
	cp glm            eesen-data/train_phn_l5_c320_V2_s20_l4/glm
	./steps_eesen/score_sclite.sh eesen-data/train_phn_l5_c320_V2_s20_l4/ eesen-data/lang_phn_sw1_fsh_tgpr/ `dirname $@`
	cp build/output/*.sbv build/output/*.trs `dirname $@`/scoring
	cp build/trans/*/eesen8/decode/score_5/*.tra `dirname $@`/scoring

decode-address-v7/wer:
	mkdir -p `dirname $@`/score_2 `dirname $@`/score_3 `dirname $@`/score_4 `dirname $@`/score_5 `dirname $@`/score_6 `dirname $@`/score_7 `dirname $@`/score_8 `dirname $@`/score_9
	touch `dirname $@`/lat.1.gz
	cp rv-address-20160214.stm eesen-data/train_phn_l5_c320_V2_s20_l4/stm
	cp glm                     eesen-data/train_phn_l5_c320_V2_s20_l4/glm
	./steps_eesen/score_sclite.sh eesen-data/train_phn_l5_c320_V2_s20_l4/ eesen-data/lang_phn_sw1_fsh_tgpr/ `dirname $@`
	cp build/output/*.sbv build/output/*.trs `dirname $@`/scoring
	cp build/trans/*/eesen8/decode/score_5/*.tra `dirname $@`/scoring

# Meta-target that deletes all files created during processing a file. Call e.g. 'make .etteytlus2013.clean
.%.clean:
	rm -rf build/audio/base/$*.wav build/audio/segmented/$* build/diarization/$* build/trans/$* build/sid/$*

# Also deletes the output files	
.%.cleanest: .%.clean
	rm -rf build/output/$*.{trs,txt,ctm,with-compounds.ctm,sbv}

# Clean everything
clean:
	rm -rf build/output/base/* build/output/segmented/* build/diarization/* build/trans/* build/output/* Log/* src-audio/*
