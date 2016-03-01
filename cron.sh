#!/bin/bash

datadir="/home/docker/box/adcs"
ls -l ${datadir} > /tmp/p
if [ ! -f /tmp/o ]; then
  echo "" > /tmp/o
fi
diff --new-line-format=%L --unchanged-line-format= --old-line-format= /tmp/o /tmp/p | awk -v d=$datadir '/.mp3|.wav/ { if (NF > 2) { printf ("%s/%s\n", d, $NF) } }' | xargs -n 1 -r sbatch ./slurm.sh
#diff /tmp/o /tmp/p | grep ">" | sed 's/> //' | awk ' { printf ("\"/home/docker/islpc21/%s\"\n", $0) } ' | xargs -n 1 -r sbatch /opt/kaldi-offline-transcriber/slurm.sh
mv /tmp/p /tmp/o
# find /home/docker/islpc21 -mmin -1 -and -type f -and -not \( -name "*.trs" -or -name ".txt" \) -exec sbatch /opt/kaldi-offline-transcriber/slurm.sh {} \;
