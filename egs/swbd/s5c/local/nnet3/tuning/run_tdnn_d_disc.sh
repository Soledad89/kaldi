#!/bin/bash

# This script does discriminative training on top of the CE nnet3 system
# from run_tdnn_d.  To simplify things, this assumes you are using the "speed-perturbed" data
# (--speed_perturb true, which is the default) in the baseline run_tdnn_d.sh script.
#
# note: this relies on having a cluster that has plenty of CPUs as well as GPUs,
# since the lattice generation runs in about real-time, so takes of the order of
# 1000 hours of CPU time.


set -e
set -uo pipefail

stage=1
train_stage=-10 # can be used to start training in the middle.
get_egs_stage=0
use_gpu=true  # for training
cleanup=false  # run with --cleanup true --stage 6 to clean up (remove large things like
               # alignments and degs).
degs_dir=  # set this to use preexisting degs.
nj=400 # have a high number of jobs because this could take a while, and we might
       # have some stragglers.

. ./cmd.sh
. ./path.sh
. ./utils/parse_options.sh

graph_dir=exp/tri4/graph_sw1_tg
srcdir=exp/nnet3/tdnn_d_sp
train_data_dir=data/train_nodup_sp_hires
online_ivector_dir=exp/nnet3/ivectors_train_nodup_sp_hires


## Objective options
criterion=smbr
one_silence_class=true

# you can set --disc-affix if you run different configurations, e.g. --disc-affix "_b"
disc_affix=

dir=${srcdir}_${criterion}${disc_affix}

## Egs options.  Give quite a few choices of chunk length,
## so it can split utterances without much gap or overlap.
frames_per_eg=300,280,150,120,100
frames_overlap_per_eg=0
frames_per_chunk_decoding=200
## these context options should match the training condition. (chunk_left_context,
## chunk_right_context)
## We set --extra-left-context-initial 0 and --extra-right-context-final 0
## directly in the script below, but this should also match the training condition.
## Note: extra-left-context and extra-right-context are 0 because this is a TDNN,
## it's not a recurrent model like an LSTM or BLSTM.
extra_left_context=0
extra_right_context=0


## Nnet training options
effective_learning_rate=0.0000125
max_param_change=1
num_jobs_nnet=4
num_epochs=3
regularization_opts=          # Applicable for providing --xent-regularize and --l2-regularize options,
                              # in chain models.
minibatch_size="300=32,16/150=64,32"  # rule says: if chunk size is closer to 300, use minibatch size 32 (or 16 for mop-up);
                                      # if chunk size is closer to 150, use mini atch size of 64 (or 32 for mop-up).

last_layer_factor=0.1         # prevent the final layer from learning too fast;
                              # this can be a problem.

## Decode options
decode_start_epoch=1 # can be used to avoid decoding all epochs, e.g. if we decided to run more.

if $use_gpu; then
  if ! cuda-compiled; then
    cat <<EOF && exit 1
This script is intended to be used with GPUs but you have not compiled Kaldi with CUDA
If you want to use GPUs (and have them), go to src/, and configure and make on a machine
where "nvcc" is installed.  Otherwise, call this script with --use-gpu false
EOF
  fi
  num_threads=1
else
  # Use 4 nnet jobs just like run_4d_gpu.sh so the results should be
  # almost the same, but this may be a little bit slow.
  num_threads=16
fi

if [ ! -f ${srcdir}/final.mdl ]; then
  echo "$0: expected ${srcdir}/final.mdl to exist"
  exit 1;
fi

if [ $stage -le 1 ]; then
  # hardcode no-GPU for alignment, although you could use GPU [you wouldn't
  # get excellent GPU utilization though.]
  steps/nnet3/align.sh  --cmd "$decode_cmd" --use-gpu false \
    --frames-per-chunk $frames_per_chunk_decoding \
    --extra-left-context $extra_left_context --extra-right-context $extra_right_context \
    --extra-left-context-initial 0 --extra-right-context-final 0 \
    --online-ivector-dir $online_ivector_dir \
    --nj $nj $train_data_dir data/lang $srcdir ${srcdir}_ali ;
fi


if [ -z "$degs_dir" ]; then

  if [ $stage -le 2 ]; then
    if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${srcdir}_degs/storage ]; then
      utils/create_split_dir.pl \
        /export/b{09,10,11,12}/$USER/kaldi-data/egs/swbd-$(date +'%m_%d_%H_%M')/s5/${srcdir}_degs/storage ${srcdir}_degs/storage
    fi
    if [ -d ${srcdir}_degs/storage ]; then max_copy_jobs=10; else max_copy_jobs=5; fi

    steps/nnet3/get_degs.sh \
      --cmd "$decode_cmd --mem 10G" --num-threads 3 \
      --max-copy-jobs $max_copy_jobs \
      --extra-left-context $extra_left_context \
      --extra-right-context $extra_right_context \
      --extra-left-context-initial 0 --extra-right-context-final 0 \
      --frames-per-chunk-decoding "$frames_per_chunk_decoding" \
      --stage $get_egs_stage \
      --online-ivector-dir $online_ivector_dir \
      --frames-per-eg $frames_per_eg --frames-overlap-per-eg $frames_overlap_per_eg \
      $train_data_dir data/lang ${srcdir} ${srcdir}_ali ${srcdir}_degs || exit 1
  fi
fi

if [ $stage -le 3 ]; then
  [ -z "$degs_dir" ] && degs_dir=${srcdir}_degs
  steps/nnet3/train_discriminative.sh --cmd "$decode_cmd" \
    --stage $train_stage \
    --effective-lrate $effective_learning_rate --max-param-change $max_param_change \
    --criterion $criterion --drop-frames true \
    --num-epochs $num_epochs --one-silence-class $one_silence_class --minibatch-size "$minibatch_size" \
    --num-jobs-nnet $num_jobs_nnet --num-threads $num_threads \
    --regularization-opts "$regularization_opts" \
    --last-layer-factor $last_layer_factor \
    ${degs_dir} $dir
fi

if [ $stage -le 4 ]; then
  for x in `seq $decode_start_epoch $num_epochs`; do
    for decode_set in train_dev eval2000; do
      num_jobs=`cat data/${decode_set}_hires/utt2spk|cut -d' ' -f2|sort -u|wc -l`
      for iter in epoch$x epoch${x}_adj; do

        steps/nnet3/decode.sh --nj $num_jobs --cmd "$decode_cmd" --iter $iter \
          --online-ivector-dir exp/nnet3/ivectors_${decode_set} \
          $graph_dir data/${decode_set}_hires $dir/decode_${decode_set}_sw1_tg_${iter} || exit 1;

        steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" \
          data/lang_sw1_{tg,fsh_fg} data/${decode_set}_hires \
          $dir/decode_${decode_set}_${iter}_sw1_{tg,fsh_fg} || exit 1;
      ) &
    done
  done
fi
wait;

if [ $stage -le 5 ] && $cleanup; then
  # if you run with "--cleanup true --stage 6" you can clean up.
  # actually, keep the alignments in case we need them later.. they're slow to
  # create, and quite big.
  # rm ${srcdir}_ali/ali.*.gz || true

  steps/nnet2/remove_egs.sh ${srcdir}_degs || true
fi

wait;
exit 0;