# pms-postprocessing
Post processing scripts to augment the Plex Media Server DVR functionality.

PMS (Plex Media Server) includes DVR functionality for PlexPass subscribers. Typically DVR tuners in Plex capture and store the native broacast file format. In ATSC 1.0 broadcast region(s) this probably means MPEG2/TS files. These files, MPEG2 in particular, take up more storage space compared to H264 or H265 at the same (subjective) quality.

PMS offers a POSTPROCESSING step that allows for modification of the captured video file prior to it being added to the PMS library. This provides a good opportunity to recompress (or perform other operations on) the fat broadcast file.

The scripts in this repository are designed to be copied to your Plex server and specified in the global DVR settings POSTPROCESSING field. Only one script may be used, as-is, by PMS. Multiple scripts could be chained by a parent script -- that is outside the scope of this repository.

## transcode-internal.sh
Converts the captured file (tested w/ MPEG2/AC3) to a lower bit-rate H264/AAC file. The script uses a default bitrate calculation based on the frame size and frame rate. It also encodes the source audio stream into a stereo AAC stream with a DPLII mix (Dolby ProLogic compatible device required for multi-channel sound). NVDEC/NVENC hardware acceleration will be used if supported by the system (if nVidia HW transcoding works in Plex, it will probably work here).

*This script uses the PMS built-in **Plex Transcoder** FFMPEG build. It does not require the installation of any additional video encoders.*

### Requirements
* Plex Media Server
* Linux
* /bin/bash
* (optional) nVidia GPU and drivers for HW accelerated encoding

### Environment Variables (configuration)
No environment variables are required for operation. However, some encoding defaults can be overriden by the following environment variables:

* `AACRATE` - AAC audio bitrate in Kb/s (default: 192)
* `VBRMULT` - Average video bitrate multiplier. Setting to 2.0 will double the average bitrate. 0.5 will cut the bitrate in half.(default: 1.0)
* `TMPFOLDER` - Temporary location for in-process transcoding (default: `/tmp`)
* `PPFORMAT` - Output file format. Either `mp4` or `mkv`. `mp4` supports FFMPEG *faststart* flag. (default: `mp4`)

### Usage
1. Copy to your PMS scripts folder (`/config/Library/Application Support/Plex Media Server/Scripts/`)
    * Make sure it is executable (`chmod +x transcode_internal.sh`)
2. Edit your PMS DVR settings and specify `transcode_internal.sh` as the postprocessing script name

### Behaviour
When the PMS DVR finishes a recording it will call this script with the recently recorded filename as the only parameter. This script will attempt to transcode the recorded file into the configured file format (see above).
1. Attempt to detect if the recorded file is interlaced. If so, deinterlacing will be used.
2. Attempt to read video dimensions and frame rate from recorded file.
3. Attempt to transcode the recorded file using NVENC acceleration.
    * Upon failure, attempt to transcode using the libx264 software encoder.
4. Cleanup temporary files.
    * (Success) Create new file with configured file format (above). Delete original recorded file (e.g., recording.ts).
    * (Failure) Remove any temporary transcoded file. Log an error in a log in the `TEMPFOLDER`.
5. PMS adds whichever file remains to the library.

### Regarding Bitrate...
Beauty is in the eye of the beholder, thus the appropriate bitrate for video encoding is very subjective. Goals with the default settings in this script are as follows:
* Lower bitrate than the source MPEG2 file to conserve storage space (i.e., smaller file size)
* Not so low that the video looks *bad* <- see... *that's* subjective

From eyeball analysis of the resulting files, a target average video bitrate of ~4,000 Kbps for 1280x720@60fps was found to meet the above goals. From that a very simple calculation was derived to try and achieve a similar quality standard at a predictable file size. In essence, the formula determines a per-pixel bitrate:

**WIDTH** * **HEIGHT** * **FRAMERATE** == *PIXELS_PER_SECOND*

*PIXELS_PER_SECOND* * **BITRATE_CONSTANT** = *AVERAGE_BITRATE*

By default, the **BITRATE_CONSTANT** is 0.000072 Kb, or in other words, each pixel is alloted 0.000072 Kb per second. The following table illustrates the calculated bitrates for standard ATSC video formats:

| Width | Height | FPS | Pixels per second | Bitrate (Kbps)
---:|---:|---:|---:|---:
704 | 480 | 29.97 | 10127462.4 | 729
1280 | 720 | 59.94 | 55240704 | 3977
1920 | 1080 | 29.97 | 62145792 | 4474

The **BITRATE_CONSTANT** can be overidden by setting the `PPSRATE` environment variable (default: 0.000072). However, small changes to that number can have drastic downstream consequences. Instead, consider setting the `VBRMULT` (default: 1.0) environment variable to add a multiplier to the final bitrate calculation (see above).

**But why not just use x264's CQP (Constant Quantization Parameter) encoding?**
If only I could. There exists two main reasons *constant quality* encoding is not used:
1. CQP results in an unpredictable file size. It all depends on what is in the video (Rambo movies, slideshows, or golf -- in order of decreasing action). Getting reliably-small files can only be achieved by using scarily-large CQP values.
2. The implementation of NVENC used in Plex's FFMPEG seems very determined to target a 2000 Kbps average bitrate regardless of the constant quality value specified. NVENC really needs its bitrates specified.
