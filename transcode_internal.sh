#!/bin/bash

###############################################################################
# transcode_internal.sh
# *****************************************************************************
#       Author: cedarrapidsboy
#     Contribs: nebhead (https://github.com/nebhead/PlexPostProc)
#      License: MIT License (https://spdx.org/licenses/MIT.html
# *****************************************************************************
#      Purpose: For use as a Plex DVR Postprocessing script. Converts captured
#               ATSC MPEG2/TS files into H264/MP4 or H264/MKV at lower 
#               bitrates. Removes source file upon successful conversion.
# Requirements: Plex Server (1.19.3.2764 tested), Linux, Bash
#        Usage: transcode_internal.sh <file> (see README.md)
###############################################################################

###############################################################################
# CONSTANTS
###############################################################################
: "${AACRATE:="192"}"      # Kb/s for AAC audio (stereo DPLII downmix)
: "${PPSRATE:="0.000072"}" # WARNING: DO NOT CHANGE - USE VBRMULT INSTEAD
: "${VBRMULT:="1.0"}"      # Adjusts average video bitrate ("2.0" == 2X)
: "${TMPFOLDER:="/tmp"}"   # In-process transcoded file, transcode logs
: "${PPFORMAT:="mp4"}"     # Output format <mkv|mp4>
: "${ONLYMPEG2:="false"}"  # Only transcode mpeg2video sources

###############################################################################
# INITIALIZATION
###############################################################################
ulimit -c 0        # Disable core dumps
LOGFILE="$TMPFOLDER/transcode.$(date +"%Y%m%d").log" # Create a unique log file.
touch "${LOGFILE}" # Create the log file
FILENAME=$1 	   # %FILE% - Filename of original file
TEMPFILENAME="$(mktemp ${TMPFOLDER}/transcode.XXXXXXXX.${PPFORMAT})"  # Temporary File Name for transcoding

###############################################################################
# FUNCTION check_errs
# *****************************************************************************
# Examine non-zero argument $1 and log the error $2. Remove temp file.
# Kills the script on non-zero $1. Otherwise GNDN.
###############################################################################
check_errs()
{
   if [ "${1}" -ne "0" ]; then
      echo "$(date +"%Y%m%d-%H%M%S") ERROR: ${1} : ${2}" \
	     | tee -a $LOGFILE
	  rm "${TEMPFILENAME}"
      exit ${1}
   fi
}

###############################################################################
# FUNCTION do_nothing
# *****************************************************************************
# Echo a message and abandon the script. Remove temp file.
# Kills the script.
###############################################################################
do_nothing()
{
   echo "$(date +"%Y%m%d-%H%M%S") WARNING: Exiting script : ${1}" \
      | tee -a $LOGFILE
   rm "${TEMPFILENAME}"
   exit 0
}

###############################################################################
# SCRIPT START
###############################################################################

###############################################################################
# ".../Plex Transcoder" requires some custom FFMPEG libraries
# Exact path may change wrt release -- discover it
###############################################################################
export FFMPEG_EXTERNAL_LIBS="$(find ~/Library/Application\ Support/Plex\ Media\ Server/Codecs/ -name "libmpeg2video_decoder.so" -printf "%h\n")/"
check_errs $? "Failed to locate plex encoder libraries. libmpeg2video_decoder.so not found."

###############################################################################
# Grab some dimension and framerate info so we can set bitrates
# *****************************************************************************
# Runtime: <1s
###############################################################################
DIM="$(/usr/lib/plexmediaserver/Plex\ Transcoder -i "$FILENAME" 2>&1 \
   | grep "Stream #0:0" \
   | perl -lane 'print "$1 $2 $3" if /Video: (\w+) .+, (\d{3,})x(\d{3,})/')"
ISMPEG2=$(echo ${DIM} | perl -lane 'print "true" if $F[0] eq "mpeg2video"')
HEIGHT=$(echo ${DIM} | perl -lane 'print $F[2]')
WIDTH=$(echo ${DIM} | perl -lane 'print $F[1]')
FPS="$(/usr/lib/plexmediaserver/Plex\ Transcoder -i "$FILENAME" 2>&1 \
   | grep "Stream #0:0" \
   | perl -lane 'print $1 if /, (\d+(.\d+)*) fps/')"

if [[ -z $ISMPEG2 && $ONLYMPEG2 == "true" ]]; then
   # Input video is MPEG2 and the env variable is set to only encode MPEG2
   do_nothing "Source video codec is not MPEG2 and ONLYMPEG2 is defined."
fi

if [[ -z $WIDTH || -z $HEIGHT || -z $FPS ]]; then
   check_errs 400 "Unable to determine input video dimensions."
fi

###############################################################################
# Analyze input video and grab the FFMPEG deinterlace string (or "")
# *****************************************************************************
# Runtime: Just a few seconds (1000 frames analyzed)
# DEINT = "" (progressive) or "-vf yadif=0:0:0" or "-vf yadif=0:1:0"
###############################################################################
DEINT="$(/usr/lib/plexmediaserver/Plex\ Transcoder -i "$FILENAME" \
   -filter:v idet -frames:v 1000 -an -f h264 -y /dev/null 2>&1 \
   | grep "Multi frame detection:" \
   | perl -lane 'if (/TFF:\s+(\d+)\s+BFF:\s+(\d+)\s+Progressive:\s+(\d+)/){print "-vf yadif=0:0:0" if ($1>$2 && $1>$3);print "-vf yadif=0:1:0" if ($2>$1 && $2>$3);print "" if ($3>$1 && $3>$2);}')"
   
###############################################################################
# Calculate average bitrate based on frame size and frame rate
###############################################################################
BITRATE="$( echo ${WIDTH} ${HEIGHT} ${FPS} ${PPSRATE} ${VBRMULT} \
   | perl -lane 'print int($F[0]*$F[1]*$F[2]*$F[3]*$F[4]+0.5);')"
BITMAX="$(echo ${BITRATE} | perl -lane 'print ($F[0]*2)')"
BUFFER="$(echo ${BITRATE} | perl -lane 'print ($F[0]*3)')"

echo "INFO -           Dimensions: ${WIDTH} x ${HEIGHT}"
echo "INFO -            Framerate: ${FPS}"
echo "INFO -  De-interlace filter: \"${DEINT}\""
echo "INFO -   Calculated bitrate: ${BITRATE}"
echo "INFO -     Max bitrate (2x): ${BITMAX}"
echo "INFO - Encoding buffer (3x): ${BUFFER}"

###############################################################################
# Transcode input video into a more efficient format
# *****************************************************************************
# Video Codec: H264_NVEC (preferred) or H264 
# Audio Codec: AAC (stereo DPLII downmix)
# File Format: MKV
###############################################################################
/usr/lib/plexmediaserver/Plex\ Transcoder -y -hide_banner \
   -hwaccel nvdec -i "${FILENAME}" \
   -c:v h264_nvenc -b:v ${BITRATE}k -maxrate:v ${BITMAX}k -profile:v high \
   -bf:v 3 -bufsize:v ${BUFFER}k -preset:v hq -forced-idr:v 1 ${DEINT} \
   -c:a aac -ac 2 -b:a ${AACRATE}k -filter:a aresample=matrix_encoding=dplii \
   -movflags +faststart \
   "${TEMPFILENAME}"
ERRCODE=$?
if [[ "${ERRCODE}" -ne "0" ]]; then   
   # For numerous reasons, NVDEC/NVENC may fail. Try pure SW encoding.
   echo "$(date +"%Y%m%d-%H%M%S") WARNING: ${ERRCODE} : Fail-over to libx264." \
      | tee -a $LOGFILE
   /usr/lib/plexmediaserver/Plex\ Transcoder -y -hide_banner \
      -i "${FILENAME}" \
      -c:v libx264 -b:v ${BITRATE}k -maxrate:v ${BITMAX}k -profile:v high \
      -bf:v 3 -bufsize:v ${BUFFER}k -preset:v veryfast -forced-idr:v 1 ${DEINT} \
      -c:a aac -ac 2 -b:a ${AACRATE}k -filter:a aresample=matrix_encoding=dplii \
      -movflags +faststart \
	  "${TEMPFILENAME}"
fi
check_errs $? "Encoding failed after falling back to libx264."

###############################################################################
# Rename temporary MKV file
# Remove original file
###############################################################################
mv -f "${TEMPFILENAME}" "${FILENAME%.*}.${PPFORMAT}"
check_errs $? "Error moving temporary file. Source preserved."
rm -f "${FILENAME}"
check_errs $? "Error removing original file. Looks like a 2 for 1 sale."

###############################################################################
# SCRIPT SUCCESS!
###############################################################################