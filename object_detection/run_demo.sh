#!/bin/bash

# Show usage
function show_usage() {
    cat <<EOF
Usage: run_demo.sh
-h, --help
  Display this help message.
--model MODEL
	Set name of paddle model.
--device DEVICE
  Set device to run.
EOF
}

while (( $# )); do
    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;

        --model)
            if [ $# -gt 1 ]
            then
                export MODEL_NAME="$2"
                shift 2
            else
                echo 'ERROR: --model requires a non-empty argument' >&2
                show_usage >&2
                exit 1
            fi
            ;;

        --device)
            if [ $# -gt 1 ]
            then
                export DEVICE="$2"
                shift 2
            else
                echo 'ERROR: --device requires a non-empty argument' >&2
                show_usage >&2
                exit 1
            fi
            ;;

        -*|--*)
            echo "Error: Unknown flag: $1" >&2
            show_usage >&2
            exit 1
            ;;
    esac
done

echo "Device name is $DEVICE"
if [ "$DEVICE" == "cortex-m55" ]; then
   RUN_DEVICE_NAME="M55"
   VHT_Platform="VHT_MPS3_Corstone_SSE-300"
   TVM_TARGET="cortex-m55"
elif [ "$DEVICE" == "cortex-m85" ]; then
   RUN_DEVICE_NAME="M85"
   VHT_Platform="VHT_Corstone_SSE-310"
   TVM_TARGET="cortex-m85"
else
  echo 'ERROR: --device only support cortex-m55/cortex-m85' >&2
  exit 1
fi

# download paddle model
echo "Model name is $MODEL_NAME"
if [ "$MODEL_NAME" == "Picodet" ]; then
  if [ ! -e picodet_s_320_coco_lcnet_no_nms.tar ]; then
    wget https://bj.bcebos.com/v1/paddledet/deploy/Inference/picodet_s_320_coco_lcnet_no_nms.tar
    tar -xf picodet_s_320_coco_lcnet_no_nms.tar
    #rm -rf picodet_s_320_coco_lcnet_no_nms.tar
    mv picodet_s_320_coco_lcnet_no_nms model
  fi
else
  echo 'ERROR: --model only support Picodet' >&2
  exit 1
fi

# convert paddle model to onnx model
paddle2onnx --model_dir  "${PWD}/model" \
            --model_filename model.pdmodel \
            --params_filename model.pdiparams \
            --save_file model.onnx
rm -rf "${PWD}/model"

# convert onnx model to tvm model
python3 -m tvm.driver.tvmc compile --target=cmsis-nn,c \
    --target-cmsis-nn-mcpu="${TVM_TARGET}" \
    --target-c-mcpu="${TVM_TARGET}" \
    --runtime=crt \
    --executor=aot \
    --executor-aot-interface-api=c \
    --executor-aot-unpacked-api=1 \
    --pass-config tir.usmp.enable=1 \
    --pass-config tir.usmp.algorithm=hill_climb \
    --pass-config tir.disable_storage_rewrite=1 \
    --pass-config tir.disable_vectorize=1 model.onnx \
    --output-format=mlf \
    --model-format=onnx \
    --module-name=det \
    --input-shapes image:[1,3,320,320] \
    --output=det.tar
rm model.onnx

# decompression cls.tar
mkdir -p "${PWD}/det"
tar -xvf det.tar -C "${PWD}/det"
rm det.tar

# create input and output head file
 python3 ./convert_image.py ./image/000000014439_640x640.jpg

# build
 csolution list packs -s object_detection.csolution.yml -m > packs.txt
 cpackget update-index
 cpackget add -f packs.txt

 PROJECT_FILE_NAME="object_detection+$MODEL_NAME$RUN_DEVICE_NAME.cprj"
 echo "Project file name is $PROJECT_FILE_NAME"
 cbuild "$PROJECT_FILE_NAME"

 rm -rf "${PWD}/cls"
 rm "${PWD}/include/inputs.h"
 rm "${PWD}/include/outputs.h"

 # run
 $VHT_Platform  -C cpu0.CFGDTCMSZ=15 \
               -C cpu0.CFGITCMSZ=15 \
               -C mps3_board.uart0.out_file=\"-\" \
               -C mps3_board.uart0.shutdown_tag=\"EXITTHESIM\" \
               -C mps3_board.visualisation.disable-visualisation=1 \
               -C mps3_board.telnetterminal0.start_telnet=0 \
               -C mps3_board.telnetterminal1.start_telnet=0 \
               -C mps3_board.telnetterminal2.start_telnet=0 \
               -C mps3_board.telnetterminal5.start_telnet=0 \
               "out/object_detection/$MODEL_NAME$RUN_DEVICE_NAME/object_detection.axf" \
               --stat

 # clean
 rm -rf out
 rm -rf tmp
 rm -rf packs.txt