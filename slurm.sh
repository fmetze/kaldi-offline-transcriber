#!/bin/bash

#SBATCH -s
#SBATCH -n 1
#SBATCH -o Log/%j.o
#SBATCH -e Log/%j.e
#SBATCH -D /opt/kaldi-offline-transcriber
#SBATCH --get-user-env

echo "Starting at `date`, in `pwd`"
#./speech2text.sh --nnet2-online false --clean false --filter true --trs build/output/`basename -s .flac "${1}"`.trs "${1}"
if [ `soxi -c "${1}"` -eq 2 ]; then
    ./speech2text.sh --nnet2-online false --clean true  --filter true  --sbv "${1%.*}.1.sbv" --trs "${1%.*}.1.trs" "${1}" --channel 1
    find build/output -name "`basename ${1%.*}`.*" -exec rm {} \;
    ./speech2text.sh --nnet2-online false --clean false --filter true  --sbv "${1%.*}.2.sbv" --trs "${1%.*}.2.trs" "${1}" --channel 2
else
    ./speech2text.sh --nnet2-online false --clean true  --filter false --sbv "${1%.*}.sbv"   --trs "${1%.*}.trs"   "${1}" 
fi
echo "Done ($?) at `date`, ran on $SLURM_NODELIST ($SLURM_NNODES, $SLURM_NPROCS)"
