/* esp32t video path options. Added AHEAD of uvc_defs.v in the build file list,
   whose geometry defines are `ifndef-guarded so anything set here wins.

   UVC_RESTAMP, and deliberately NOT UVC_DUAL_RES yet.

   With it, uvc_restamp crosses the raster from hClk to pClk on RGB666 through
   ping-pong line buffers and the colour space converter and everything after it
   run in the USB clock domain. REP stays 1, so the device still emits 160x144
   and the shipping behaviour is the reference to compare against - if this
   changes the picture at all, the crossing is wrong, and that is a much smaller
   question than "does 320x288 work".

   Here hClk is gClk (~8.388 MHz) and pClk is PHY_CLKOUT (60 MHz), so the
   crossing is doing more work than in the bench examples, where hClk is the
   24 MHz board oscillator.

   UVC_DUAL_RES is now on too, which IS product-visible: the device advertises a
   second frame descriptor and a host may pick either. bFrameIndex 1 is 320x288
   and is bDefaultFrameIndex, so a host that does not choose gets the larger
   one; bFrameIndex 2 is the native 160x144.

   320x288 at 60fps is 11.06 MB/s, past what one 1024-byte transaction per
   microframe carries (8.10 MB/s), so it depends on PACKET_PER_MFRAME=2 and
   ADDITIONAL_PACKET=1 in uvc_defs.v - the high-bandwidth isochronous work.

   WIDTH/HEIGHT are the OUTPUT geometry the descriptors advertise; WIDTH2/
   HEIGHT2 are the SOURCE, which is what the LCD feed actually delivers and what
   uvc_restamp is sized from. */
`define UVC_RESTAMP
`define UVC_DUAL_RES

`define WIDTH    16'd320
`define HEIGHT   16'd288
`define WIDTH2   16'd160
`define HEIGHT2  16'd144
