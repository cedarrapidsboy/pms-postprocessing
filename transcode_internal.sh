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
: "${TRANSCODE:="true"}"   # Perform transcode step, otherwise just copy
: "${COMCHAP:="false"}"    # Create chapter marks for commercials (leaves the 
                           #    commercials in -- non-destructive)
: "${AACRATE:="192"}"      # Kb/s for AAC audio (stereo DPLII downmix)
: "${PPSRATE:="0.000072"}" # WARNING: DO NOT CHANGE - USE VBRMULT INSTEAD
: "${VBRMULT:="1.0"}"      # Adjusts average video bitrate ("2.0" == 2X)
: "${TMPFOLDER:="/tmp"}"   # In-process transcoded file, transcode logs
: "${PPFORMAT:="mp4"}"     # Transcode output format <mkv|mp4> (mkv will be
                           #    forced for COMCHAP-only runs)
: "${ONLYMPEG2:="false"}"  # Only transcode mpeg2video sources

###############################################################################
# INITIALIZATION
###############################################################################
ulimit -c 0                # Disable core dumps
LOGFILE="$TMPFOLDER/transcode.$(date +"%Y%m%d").log" # Create a unique log file.
touch "${LOGFILE}"         # Create the log file
FILENAME="${1}" 	       # %FILE% - Filename of original file
WORKINGFILE="$(mktemp ${TMPFOLDER}/working.XXXXXXXX.mkv)"

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
	     | tee -a "${LOGFILE}"
	  rm -f "${WORKINGFILE}"
      exit ${1}
   fi
}

###############################################################################
# SCRIPT START
###############################################################################

###############################################################################
# ".../Plex <executables>" require some custom FFMPEG libraries
# Exact path may change wrt release -- discover it
###############################################################################
export FFMPEG_EXTERNAL_LIBS="$(find ~/Library/Application\ Support/Plex\ Media\ Server/Codecs/ -name "libmpeg2video_decoder.so" -printf "%h\n")/"
check_errs $? "Failed to locate plex encoder libraries. libmpeg2video_decoder.so not found."

###############################################################################
# Remux the source file into our working format
###############################################################################
/usr/lib/plexmediaserver/Plex\ Transcoder -y -hide_banner -i "${FILENAME}" -c:v copy -c:a copy -c:s copy -c:d copy -c:t copy "${WORKINGFILE}"
check_errs $? "Failed to remux ${FILENAME}."
WORKSIZE=$(stat -c%s "${WORKINGFILE}")

###############################################################################
# Find commercials and generate chapter marks.
# *****************************************************************************
# Does not transcode but will remux TS source files into MKV.
# Deletes original file.
# INPUT: an MKV file
# OUTPUT: an MKV file with chapters
###############################################################################

if [[ "${COMCHAP}" == "true" ]]; then
   # COMSKIP STUFF HERE
	echo "$(date +"%Y%m%d-%H%M%S") INFO: Commercial detection and chapter insertion starting." \
      | tee -a "${LOGFILE}"
   COMSKIP_ORG="$(find /usr/lib/plexmediaserver/ -name "comskip.ini")"
   COMSKIP_PRE="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13)"
   COMSKIP_TMP="${TMPFOLDER}/${COMSKIP_PRE}.comskip.ini"
   COMSKIP_OUT="${TMPFOLDER}/${COMSKIP_PRE}.commerge.mkv"
   cp "${COMSKIP_ORG}" "${COMSKIP_TMP}"
   echo output_ffmeta=1 >> "${COMSKIP_TMP}"
   /usr/lib/plexmediaserver/Plex\ Commercial\ Skipper --ini "${COMSKIP_TMP}" --output="${TMPFOLDER}" --output-filename="${COMSKIP_PRE}.comskip" -q "${WORKINGFILE}" "${TMPFOLDER}"
   COMSKIP_ERR=$?
   if [[ "${COMSKIP_ERR}" -ne "0" ]]; then   
      # For numerous reasons, comskip may fail.
      echo "$(date +"%Y%m%d-%H%M%S") WARNING: ${COMSKIP_ERR} : Comskip failed to generate chapters." \
         | tee -a "${LOGFILE}"
   else
      # Ready to merge in the chapter file
	  COMSKIP_ERR="0"
      /usr/lib/plexmediaserver/Plex\ Transcoder -y -hide_banner -i "${TMPFOLDER}/${COMSKIP_PRE}.comskip.ffmeta" -i "${WORKINGFILE}" -c:v copy -c:a copy -c:s copy -c:d copy -c:t copy "${COMSKIP_OUT}"
	  COMSKIP_ERR=$?
      if [[ "${COMSKIP_ERR}" -ne "0" ]]; then   
	     echo "$(date +"%Y%m%d-%H%M%S") WARNING: ${COMSKIP_ERR} : Failed to merge chapter info with source video." \
         | tee -a "${LOGFILE}"
		 rm -f "${COMSKIP_OUT}"
      else
	     # Remove original file
	     mv -f "${COMSKIP_OUT}" "${WORKINGFILE}"
	     echo "$(date +"%Y%m%d-%H%M%S") INFO: Commercial detection complete. ${WORKINGFILE} updated." \
            | tee -a "${LOGFILE}"
	  fi
   fi
   rm -f "${TMPFOLDER}/${COMSKIP_PRE}.comskip"*
fi

if [[ "${TRANSCODE}" == "true" ]]; then

   ###############################################################################
   # Grab some dimension and framerate info so we can set bitrates
   # *****************************************************************************
   # Runtime: <1s
   ###############################################################################
   DIM="$(/usr/lib/plexmediaserver/Plex\ Transcoder -i "${WORKINGFILE}" 2>&1 \
      | grep "Stream #0:0" \
      | perl -lane 'print "$1 $2 $3" if /Video: (\w+) .+, (\d{3,})x(\d{3,})/')"
   ISMPEG2=$(echo ${DIM} | perl -lane 'print "true" if $F[0] eq "mpeg2video"')
   HEIGHT=$(echo ${DIM} | perl -lane 'print $F[2]')
   WIDTH=$(echo ${DIM} | perl -lane 'print $F[1]')
   FPS="$(/usr/lib/plexmediaserver/Plex\ Transcoder -i "${WORKINGFILE}" 2>&1 \
      | grep "Stream #0:0" \
      | perl -lane 'print $1 if /, (\d+(.\d+)*) fps/')"
   ALLOK="true"
   if [[ -z $ISMPEG2 && "${ONLYMPEG2}" == "true" ]]; then
      # Input video is MPEG2 and the env variable is set to only encode MPEG2
      echo "$(date +"%Y%m%d-%H%M%S") INFO: Trasncode skipped. Source video codec is not MPEG2 and ONLYMPEG2 is defined." \
         | tee -a "${LOGFILE}"
	  ALLOK="false"
   fi

   if [[ -z $WIDTH || -z $HEIGHT || -z $FPS ]]; then
     echo "$(date +"%Y%m%d-%H%M%S") ERROR: Trasncode canceled. Unable to determine input video dimensions." \
         | tee -a "${LOGFILE}"
	  ALLOK="false"
   fi
   if [[ "${ALLOK}" == "true" ]]; then
      ###############################################################################
      # Analyze input video and grab the FFMPEG deinterlace string (or "")
      # *****************************************************************************
      # Runtime: Just a few seconds (1000 frames analyzed)
      # DEINT = "" (progressive) or "-vf yadif=0:0:0" or "-vf yadif=0:1:0"
      ###############################################################################
      DEINT="$(/usr/lib/plexmediaserver/Plex\ Transcoder -i "${WORKINGFILE}" \
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
      TEMPFILENAME="$(mktemp ${TMPFOLDER}/transcode.XXXXXXXX.mkv)"  # Temporary File Name for transcoding
      /usr/lib/plexmediaserver/Plex\ Transcoder -y -hide_banner \
        -hwaccel nvdec -i "${WORKINGFILE}" \
        -c:v h264_nvenc -b:v ${BITRATE}k -maxrate:v ${BITMAX}k -profile:v high \
        -bf:v 3 -bufsize:v ${BUFFER}k -preset:v hq -forced-idr:v 1 ${DEINT} \
        -c:a aac -ac 2 -b:a ${AACRATE}k -filter:a aresample=matrix_encoding=dplii \
        "${TEMPFILENAME}"
      ERRCODE=$?
      if [[ "${ERRCODE}" -ne "0" ]]; then   
        # For numerous reasons, NVDEC/NVENC may fail. Try pure SW encoding.
        echo "$(date +"%Y%m%d-%H%M%S") WARNING: ${ERRCODE} : Fail-over to libx264." \
         | tee -a "${LOGFILE}"
        /usr/lib/plexmediaserver/Plex\ Transcoder -y -hide_banner \
         -i "${WORKINGFILE}" \
         -c:v libx264 -b:v ${BITRATE}k -maxrate:v ${BITMAX}k -profile:v high \
         -bf:v 3 -bufsize:v ${BUFFER}k -preset:v veryfast -forced-idr:v 1 ${DEINT} \
         -c:a aac -ac 2 -b:a ${AACRATE}k -filter:a aresample=matrix_encoding=dplii \
         "${TEMPFILENAME}"
        ERRCODE=$?
        if [[ "${ERRCODE}" -ne "0" ]]; then
          echo "$(date +"%Y%m%d-%H%M%S") WARNING: ${ERRCODE} : Transcode failed." \
             | tee -a "${LOGFILE}"
          rm -f "${TEMPFILENAME}"
		else
          echo "$(date +"%Y%m%d-%H%M%S") INFO: Transcoding complete. ${TEMPFILENAME} created." \
             | tee -a "${LOGFILE}"
        fi
      fi
      ###############################################################################
      # Rename temporary MKV file
      # Remove original file
      ###############################################################################
      if [[ -f "${TEMPFILENAME}" ]]; then
        mv -f "${TEMPFILENAME}" "${WORKINGFILE}"
      fi
   fi
fi

###############################################################################
# REMUX the working file into the desired format
###############################################################################
ERRCODE=0
if [[ "$(stat -c%s "${WORKINGFILE}")" -ne "${WORKSIZE}" ]]; then
   TEMPFILENAME="$(mktemp ${TMPFOLDER}/transcode.XXXXXXXX.${PPFORMAT})"  # Temporary File Name for transcoding
   # remux the working file into the desired container -- chance to fail w/ mp4
   #    due to limitations of the container
   /usr/lib/plexmediaserver/Plex\ Transcoder -y -hide_banner -i "${WORKINGFILE}" -c:v copy \
      -c:a copy -c:s copy -c:d copy -c:t copy -movflags +faststart \
	  "${TEMPFILENAME}"
   ERRCODE=$?
   if [[ "${ERRCODE}" -ne "0" ]]; then
      echo "$(date +"%Y%m%d-%H%M%S") ERROR: ${ERRCODE} : Unable to remux working file." \
        | tee -a "${LOGFILE}"
   else
      mv -f "${TEMPFILENAME}" "${FILENAME%.*} - (transcoded).${PPFORMAT}"
	  rm -f "${FILENAME}"
   fi
   rm -f "${TEMPFILENAME}"
else
   echo "$(date +"%Y%m%d-%H%M%S") INFO: No work done. Removed ${WORKINGFILE}." \
      | tee -a "${LOGFILE}"
fi
rm -f "${WORKINGFILE}"
exit $ERRCODE
###############################################################################
# SCRIPT DONE.
###############################################################################