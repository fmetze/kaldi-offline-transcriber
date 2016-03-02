#!/bin/bash

BASEDIR=$(dirname $0)

echo "$0 $@"  # Print the command line for logging

txt=""
trs=""
ctm=""
sbv=""
md5=false
predict=false
filter=false
channel=0
clean=true
nthreads=""
nnet2_online=true
start=`date`

. $BASEDIR/utils/parse_options.sh || exit 1;

if [ $# -ne 1 ]; then
  echo "Usage: speech2text [options] <audiofile>"
  echo "Options:"
  echo "  --nthreads <n>        # Use <n> threads in parallel for decoding"
  echo "  --md5 (true|false)    # Use md5 filename during computation"
  echo "  --predict (true|false)# Run prediction"
  echo "  --filter (true|false) # Run filtering"
  echo "  --channel (0|N)       # Process only a channel 1...n"
  echo "  --txt <txt-file>      # Put the result in a simple text file"
  echo "  --trs <trs-file>      # Put the result in trs file (XML file for Transcriber)"
  echo "  --ctm <ctm-file>      # Put the result in CTM file (one line pwer word with timing information)"
  echo "  --sbv <sbv-file>      # Put the result in SBV file (subtitles for e.g. YouTube)"
  echo "  --clean (true|false)  # Delete intermediate files generated during decoding (true by default)"
  echo "  --nnet2-online (true|false) # Use one-pass decoding using online nnet2 models. 3 times faster (true by default)."
  exit 1;
fi

nthreads_arg=""
if [ ! -z $nthreads ]; then
  echo "Using $nthreads threads for decoding"
  nthreads_arg="nthreads=$nthreads"
fi

filename=$(basename "$1")
basename="${filename%.*}"

if $md5; then
  orgname="$basename"
  basename=`echo -n $orgname | md5sum | awk ' { print $1 } '`
  echo "cp -u \"$1\" $BASEDIR/src-audio/$basename.${filename##*.}"
  cp -u "$1" $BASEDIR/src-audio/$basename.${filename##*.}
else
  cp -u "$1" $BASEDIR/src-audio
fi

nnet2_online_arg="DO_NNET2_ONLINE=no"
if $nnet2_online; then
  nnet2_online_arg="DO_NNET2_ONLINE=yes"
fi

filter_arg="DO_FILTER=no"
if $filter; then
  filter_arg="DO_FILTER=yes"
fi

channel_arg="CHANNEL_NO=0"
if [ $channel -ne 0 ]; then
  channel_arg="CHANNEL_NO=$channel"
fi

(cd $BASEDIR; make -f Makefile $nthreads_arg $channel_arg $filter_arg $nnet2_online_arg build/output/$basename.{txt,trs,ctm,sbv} || exit 1; if $clean ; then make -f Makefile.asr .$basename.clean; fi)

echo "Finished transcribing, result is in files $BASEDIR/build/output/$basename.{txt,trs,ctm,sbv}"

u=`stat -c "%u" "$1"`
if [ ! -z $txt ]; then
  sudo cp $BASEDIR/build/output/${basename}.txt $txt
  sudo chown $u $txt
  echo $txt
fi

if [ ! -z $trs ]; then
  sudo cp $BASEDIR/build/output/${basename}.trs $trs
  sudo chown $u $trs
  echo $trs
fi

if [ ! -z $ctm ]; then
  sudo cp $BASEDIR/build/output/${basename}.ctm $ctm
  sudo chown $u $ctm
  echo $ctm
fi

if [ ! -z $sbv ]; then
  sudo cp $BASEDIR/build/output/${basename}.sbv $sbv
  sudo chown $u $sbv
  echo $sbv
fi

if $predict; then
  if [ -z "$orgname" ]; then
    orgname = $basename
  fi
  python ~/box/college/test.py $BASEDIR/build/output/${basename}.trs | tee /tmp/q || awk -v v="$orgname" -v s="$start" ' { printf ("\"\",\"\",\"%s\",\"%s\"\n", v, s) } ' >> ~/box/college/results/islpc21.csv
  tail -n 2 /tmp/q | tr '\n' ' ' | awk -v v="$orgname" -v s="$start" ' { printf ("%f,%f,\"%s\",\"%s\"\n", $1, $2, v, s) } ' >> ~/box/college/results/islpc21.csv
  sudo cp $BASEDIR/build/output/${basename}.trs "/home/docker/box/college/trs/$orgname.trs"
fi
