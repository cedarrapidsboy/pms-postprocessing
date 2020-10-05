#!/bin/bash
# set -x
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
# A standard location for the codecs (PMS docker image)
CONST_CODECS_01="/config/Library/Application Support/Plex Media Server/Codecs/"
# A standard location for the codecs (PMS linux package?)
CONST_CODECS_02="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Codecs/"
: "${TRANSCODE:="true"}"	# Perform transcode step, otherwise just copy
: "${COPYAUDIO:="false"}"	# Simply copy audio track, otherwise transcode
							#    audio to AAC
: "${COMCHAP:="false"}"		# Create chapter marks for commercials (leaves the 
							#    commercials in -- non-destructive)
: "${AACRATE:="192"}"		# Kb/s for AAC audio (stereo DPLII downmix)
: "${PPSRATE:="0.000072"}" 	# WARNING: DO NOT CHANGE - USE VBRMULT INSTEAD
: "${VBRMULT:="1.0"}"      	# Adjusts average video bitrate ("2.0" == 2X)
: "${TMPFOLDER:="/tmp"}"	# In-process transcoded file
: "${PPFORMAT:="mp4"}"		# Output format <mkv|mp4> (source file will be
							#    remuxed to this format if any operations are 
							#    performed)
: "${ONLYMPEG2:="false"}"	# Only transcode mpeg2video sources
: "${FFMPEGLIBS:=""}"	    # User-defined ffmpeg libs (codecs) folder
                            #    Contains (at any depth) libmpeg2video_decoder.so
                            #    I.e., /<...>/Plex Media Server/Codecs/
: "${LOGLEVEL:="1"}"        # Logging verbosity
                            #    (0=none, *1=STDOUT msgs, 2=STDOUT+STDERR)

###############################################################################
# INITIALIZATION
###############################################################################
ulimit -c 0					# Disable core dumps
FILENAME="${1}"				# %FILE% - Filename of original file
WORKINGFILE="$(mktemp ${TMPFOLDER}/working.XXXXXXXX.mkv)"
COMSKIP_CHAPTERS=""
UNIQUESTRING=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)
LOGFILE="/dev/null"
ERRFILE="/dev/null"
if [ "${LOGLEVEL}" -gt "0" ]; then
	LOGFILE="/tmp/transcode.$(date +"%Y%m%d").log" # Create a daily log file.
fi
if [ "${LOGLEVEL}" -gt "1" ]; then
	ERRFILE="/tmp/transcode.$(date +"%Y%m%d").err" # Create a daily log file.
fi
touch "${LOGFILE}"			# Create the log file
touch "${ERRFILE}"			# Create the log file
AUDIOPARMS="-c:a aac -ac 2 -b:a ${AACRATE}k -filter:a aresample=matrix_encoding=dplii"
if [ "${COPYAUDIO}" == "true" ]; then
	AUDIOPARMS="-c:a copy"
fi

###############################################################################
# FUNCTION check_errs
# *****************************************************************************
# Examine non-zero argument $1 and log the error $2. Remove temp file.
# Kills the script on non-zero $1. Otherwise GNDN.
###############################################################################
check_errs()
{
   if [ "${1}" -ne "0" ]; then
		echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] ERROR: ${1} : ${2}" \
		   | tee -a "${LOGFILE}"
		rm -f "${WORKINGFILE}"
		exit ${1}
   fi
}

###############################################################################
# SCRIPT START
###############################################################################

echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] INFO: transcode_internal.sh : Starting postprocessing for $FILENAME." \
		 | tee -a "${LOGFILE}" "${ERRFILE}"

###############################################################################
# ".../Plex <executables>" require some custom FFMPEG libraries
# Exact path may change wrt release -- discover it
###############################################################################
CODECs=""
if [ -n "$FFMPEGLIBS" ]; then
	CODECS="$(find "$FFMPEGLIBS" -name "libmpeg2video_decoder.so" -printf "%h\n")"
	check_errs $? "Failed to locate user-defined plex encoder libraries. libmpeg2video_decoder.so not found." \
		> >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2)
else
	CODECS="$(find "$CONST_CODECS_01" -name "libmpeg2video_decoder.so" -printf "%h\n")"
	if [ "$?" -ne "0" ]; then
		CODECS="$(find "$CONST_CODECS_02" -name "libmpeg2video_decoder.so" -printf "%h\n")"
		check_errs $? "Failed to locate plex encoder libraries. libmpeg2video_decoder.so not found." \
			> >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2)
	fi
fi

export FFMPEG_EXTERNAL_LIBS="$CODECS/"
echo "INFO - FFMPEG_EXTERNAL_LIBS: $FFMPEG_EXTERNAL_LIBS" > >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2)


###############################################################################
# Remux the source file into our working format
###############################################################################
/usr/lib/plexmediaserver/Plex\ Transcoder -y -hide_banner -i "${FILENAME}" \
	-c:v copy -c:a copy -c:s copy -c:d copy -c:t copy "${WORKINGFILE}" \
	> >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2)
check_errs $? "Failed to remux ${FILENAME}."
WORKSIZE=$(stat -c%s "${WORKINGFILE}")

if [[ "${TRANSCODE}" == "true" ]]; then

   ###############################################################################
   # Grab some dimension and framerate info so we can set bitrates
   # *****************************************************************************
   # Runtime: <1s
   ###############################################################################
   DIM="$(/usr/lib/plexmediaserver/Plex\ Transcoder -i "${WORKINGFILE}" 2>&1 \
		| grep "Stream #0:0" \
		| perl -lane 'print "$1 $2 $3" if /Video: (\w+).*, (\d{3,})x(\d{3,})/' \
		 > >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2))"
   ISMPEG2=$(echo ${DIM} | perl -lane 'print $F[0] if $F[0] eq "mpeg2video"')
   HEIGHT=$(echo ${DIM} | perl -lane 'print $F[2]')
   WIDTH=$(echo ${DIM} | perl -lane 'print $F[1]')
   FPS="$(/usr/lib/plexmediaserver/Plex\ Transcoder -i "${WORKINGFILE}" 2>&1 \
		| grep "Stream #0:0" \
		| perl -lane 'print $1 if /, (\d+(.\d+)*) fps/' \
		 > >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2))"
   ALLOK="true"
   if [[ -z $ISMPEG2 && "${ONLYMPEG2}" == "true" ]]; then
		# Input video is not MPEG2 and the env variable is set to only encode MPEG2
		echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] INFO: transcode_internal.sh : Transcode skipped. Source video codec is not MPEG2 and ONLYMPEG2 is defined." \
		 | tee -a "${LOGFILE}" "${ERRFILE}"
		ALLOK="false"
   fi

   if [[ -z $WIDTH || -z $HEIGHT || -z $FPS ]]; then
	 echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] ERROR: transcode_internal.sh : Transcode canceled. Unable to determine input video dimensions." \
		 | tee -a "${LOGFILE}" "${ERRFILE}"
		ALLOK="false"
   fi
   if [[ "${ALLOK}" == "true" ]]; then
		###############################################################################
		# Analyze input video and grab the FFMPEG deinterlace string (or "")
		# *****************************************************************************
		# Runtime: Just a few seconds (1000 frames analyzed)
		# DEINT      = "" (progressive) or "-vf yadif=0:0:0" or "-vf yadif=0:1:0"
		# DEINT_CUDA = <same as DEINT with string substitution to use yadif_cuda> 
		###############################################################################
		DEINT="$(/usr/lib/plexmediaserver/Plex\ Transcoder -i "${WORKINGFILE}" \
		-filter:v idet -frames:v 1000 -an -f h264 -y /dev/null 2>&1 \
		| grep "Multi frame detection:" \
		| perl -lane 'if (/TFF:\s+(\d+)\s+BFF:\s+(\d+)\s+Progressive:\s+(\d+)/){print "-vf yadif=0:0:0" if ($1>$2 && $1>$3);print "-vf yadif=0:1:0" if ($2>$1 && $2>$3);print "" if ($3>$1 && $3>$2);}' \
		 > >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2))"
		HWYADIF="hwupload_cuda,yadif_cuda"
		DEINT_CUDA="${DEINT/yadif/$HWYADIF}"		
		###############################################################################
		# Calculate average bitrate based on frame size and frame rate
		###############################################################################
		BITRATE="$( echo ${WIDTH} ${HEIGHT} ${FPS} ${PPSRATE} ${VBRMULT} \
		| perl -lane 'print int($F[0]*$F[1]*$F[2]*$F[3]*$F[4]+0.5);')"
		BITMAX="$(echo ${BITRATE} | perl -lane 'print ($F[0]*2)')"
		BUFFER="$(echo ${BITRATE} | perl -lane 'print ($F[0]*3)')"

		echo "INFO -           Dimensions: ${WIDTH} x ${HEIGHT}" > >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2)
		echo "INFO -            Framerate: ${FPS}" > >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2)
		echo "INFO -  De-interlace filter: \"${DEINT}\"" > >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2)
		echo "INFO -   Calculated bitrate: ${BITRATE}" > >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2)
		echo "INFO -     Max bitrate (2x): ${BITMAX}" > >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2)
		echo "INFO - Encoding buffer (3x): ${BUFFER}" > >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2)

		###############################################################################
		# Transcode input video into a more efficient format
		# *****************************************************************************
		# Video Codec: H264_NVEC (preferred) or H264 
		# Audio Codec: AAC (stereo DPLII downmix)
		# File Format: MKV
		###############################################################################
		echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] INFO: transcode_internal.sh : Video and audio transcoding starting." \
		 | tee -a "${LOGFILE}" "${ERRFILE}"
		echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] DEBUG: transcode_internal.sh : $FILENAME;$ISMPEG2;$WIDTH;$HEIGHT;$FPS;$DEINT;$BITRATE;$BITMAX;$BUFFER." \
		 | tee -a "${LOGFILE}" "${ERRFILE}"
		TEMPFILENAME="$(mktemp ${TMPFOLDER}/transcode.XXXXXXXX.mkv)"  # Temporary File Name for transcoding
		/usr/lib/plexmediaserver/Plex\ Transcoder -y -hide_banner \
		-hwaccel nvdec -i "${WORKINGFILE}" \
		-c:v h264_nvenc -b:v ${BITRATE}k -maxrate:v ${BITMAX}k ${DEINT_CUDA} \
		${AUDIOPARMS} \
		"${TEMPFILENAME}" > >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2)
		ERRCODE=$?
		if [[ "${ERRCODE}" -ne "0" ]]; then   
		# For numerous reasons, NVDEC/NVENC may fail. Try pure SW encoding.
		echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] WARNING: ${ERRCODE} : transcode_internal.sh : Fail-over to libx264." \
		 | tee -a "${LOGFILE}" "${ERRFILE}"
		/usr/lib/plexmediaserver/Plex\ Transcoder -y -hide_banner \
		 -i "${WORKINGFILE}" \
		 -c:v libx264 -b:v ${BITRATE}k -maxrate:v ${BITMAX}k -profile:v main \
		 -level:v 4.1 -bf:v 3 -bufsize:v ${BUFFER}k -preset:v veryfast ${DEINT} \
		 ${AUDIOPARMS} \
		 "${TEMPFILENAME}" > >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2)
		ERRCODE=$?
		if [[ "${ERRCODE}" -ne "0" ]]; then
			echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] ERROR: ${ERRCODE} : transcode_internal.sh : Transcode failed." \
			 | tee -a "${LOGFILE}" "${ERRFILE}"
			rm -f "${TEMPFILENAME}"
		else
			echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] INFO: transcode_internal.sh : Transcoding complete. ${TEMPFILENAME} created." \
			 | tee -a "${LOGFILE}" "${ERRFILE}"
		fi
		else
		 echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] INFO: transcode_internal.sh : Transcoding complete. ${TEMPFILENAME} created." \
			| tee -a "${LOGFILE}" "${ERRFILE}"
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
# Find commercials and generate chapter marks.
# *****************************************************************************
# Does not transcode but will remux TS source files into MKV.
# Deletes original file.
# INPUT: an MKV file
# OUTPUT: a chapter file
###############################################################################

if [[ "${COMCHAP}" == "true" ]]; then
   # COMSKIP STUFF HERE
	echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] INFO: transcode_internal.sh : Commercial detection and chapter insertion starting." \
		| tee -a "${LOGFILE}"
   COMSKIP_ORG="$(find /usr/lib/plexmediaserver/ -name "comskip.ini")"
   COMSKIP_PRE="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13)"
   COMSKIP_TMP="${TMPFOLDER}/${COMSKIP_PRE}.comskip.ini"
   COMSKIP_OUT="${TMPFOLDER}/${COMSKIP_PRE}.commerge.mkv"
   cp "${COMSKIP_ORG}" "${COMSKIP_TMP}"
   echo output_ffmeta=1 >> "${COMSKIP_TMP}"
   /usr/lib/plexmediaserver/Plex\ Commercial\ Skipper --ini "${COMSKIP_TMP}" --output="${TMPFOLDER}" \
		--output-filename="${COMSKIP_PRE}.comskip" -q "${WORKINGFILE}" "${TMPFOLDER}" \
		> >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2)
   COMSKIP_ERR=$?
   if [[ "${COMSKIP_ERR}" -ne "0" ]]; then   
		# For numerous reasons, comskip may fail.
		echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] WARN: ${COMSKIP_ERR} : transcode_internal.sh : Comskip failed to generate chapters." \
		 | tee -a "${LOGFILE}" "${ERRFILE}"
   elif [[ -f "${TMPFOLDER}/${COMSKIP_PRE}.comskip.ffmeta" ]]; then
	 COMSKIP_CHAPTERS="${TMPFOLDER}/${COMSKIP_PRE}.comskip.ffmeta"
   else   
		echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] WARN: ${COMSKIP_ERR} : transcode_internal.sh : Comskip output was empty." \
		 | tee -a "${LOGFILE}" "${ERRFILE}"
   fi
fi

###############################################################################
# REMUX the working file into the desired format
###############################################################################
if [[ "${COMSKIP_CHAPTERS}" != "" || "$(stat -c%s "${WORKINGFILE}")" -ne "${WORKSIZE}" ]]; then
   TEMPFILENAME="$(mktemp ${TMPFOLDER}/transcode.XXXXXXXX.${PPFORMAT})"  # Temporary File Name for transcoding
   echo TEMPFILENAME=$TEMPFILENAME
   echo WORKINGFILE=$WORKINGFILE
   if [[ "${COMSKIP_CHAPTERS}" != "" ]]; then 
		echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] INFO: transcode_internal.sh : Muxing $WORKINGFILE and $COMSKIP_CHAPTERS into $TEMPFILENAME." \
		 | tee -a "${LOGFILE}"
		echo COMSKIP_CHAPTERS=$COMSKIP_CHAPTERS
		# remux the working file into the desired container -- chance to fail w/ mp4
		#    due to limitations of the container
		/usr/lib/plexmediaserver/Plex\ Transcoder -y -hide_banner \
		   -i "$WORKINGFILE" -i "$COMSKIP_CHAPTERS" \
		 -c:v copy -c:a copy -c:s copy -c:d copy -c:t copy \
		   "$TEMPFILENAME"  > >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2)
   else
		echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] INFO: transcode_internal.sh : Remuxing $WORKINGFILE into $TEMPFILENAME." \
		 | tee -a "${LOGFILE}"
		# remux the working file into the desired container -- chance to fail w/ mp4
		#    due to limitations of the container
		/usr/lib/plexmediaserver/Plex\ Transcoder -y -hide_banner \
		   -i "$WORKINGFILE" \
		 -c:v copy -c:a copy -c:s copy -c:d copy -c:t copy \
		   "$TEMPFILENAME"  > >(tee -a "${LOGFILE}") 2> >(tee -a "${ERRFILE}" >&2)
   fi
   ERRCODE=$?
   if [[ "${ERRCODE}" -ne "0" ]]; then
		echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] ERROR: ${ERRCODE} : transcode_internal.sh : Unable to remux working file." \
		| tee -a "${LOGFILE}"
   else
		NEWFILENAME="${FILENAME%.*}.${PPFORMAT}"
		mv -f "${TEMPFILENAME}" "${NEWFILENAME}"
		echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] INFO: transcode_internal.sh : Moved $TEMPFILENAME to $NEWFILENAME." \
		 | tee -a "${LOGFILE}"
		if [[ "${FILENAME}" != "${NEWFILENAME}" ]]; then
		   rm -f "${FILENAME}"
		 echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] INFO: transcode_internal.sh : Original file format not wanted. Removed ${FILENAME}." \
			| tee -a "${LOGFILE}"
		fi
   fi
   rm -f "${TEMPFILENAME}"
   echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] INFO: transcode_internal.sh : Postprocessing completed. Removed ${TEMPFILENAME}." \
		| tee -a "${LOGFILE}"

else
   echo "$(date +"%Y%m%d-%H%M%S") [${UNIQUESTRING}] INFO: transcode_internal.sh : Postprocessing completed. No work done. Removed ${WORKINGFILE}." \
		| tee -a "${LOGFILE}"
fi
rm -f "${WORKINGFILE}"
rm -f "${TMPFOLDER}/${COMSKIP_PRE}.comskip"*
exit 0
###############################################################################
# SCRIPT DONE.
###############################################################################
