## v1 - Initial version
* **Feature** - Transcode from recorded format to H264/AAC
* **Feature** - Uses NVDEC/NVENC if present and configured
* **Bug** - (reported) Occasional transcoding failure (original recording is reserved)
```
May 15 20:32:53 Plex01 Plex Media Server[1542]: mv: cannot move ‘/media/PlexMedia1/transcode/transcode.0dFnRGMf.mp4’ to “/media/PlexMedia1/TVShows/.grab/cb4c5f91b9fc40c194824db62d6697e6d00c871f-c51305b7fd58fd3c0df2435013966473986cda3/America Says - S02E35 - Mabel’s Family vs. Bartender.mp4”: No such file or directory
May 15 20:32:53 Plex01 Plex Media Server[1542]: 20200515-203253 ERROR: 1 : Error moving temporary file. Source preserved.
```
## v2 - Comskip chapter support
* **Feature** - Chapters can now be added to the video to reflect comskip-detected commercials.
* **Refactor** - Script now maintains its own MKV working file to isolate excessive changes to the source. Results in several remuxing steps -- unfortunately increases IO utilization.
