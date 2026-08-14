/* USB Video device product defines */
`define BCD_DEVICE  16'h0100
`define VENDOR_ID   16'h20B1
`define PRODUCT_ID  16'h1DE0

/* USB Sub class and Protocol codes */
`define USB_VIDEO_CONTROL               8'h01
`define USB_VIDEO_STREAMING             8'h02
`define USB_VIDEO_INTERFACE_COLLECTION  8'h03

/* Descriptor types */
`define USB_DESCTYPE_CS_INTERFACE   8'h24
`define USB_DESCTYPE_CS_ENDPOINT    8'h25

/* USB Video Control Subtype Descriptors */
`define USB_VC_HEADER           8'h01
`define USB_VC_INPUT_TERMINAL   8'h02
`define USB_VC_OUPUT_TERMINAL   8'h03
`define USB_VC_SELECTOR_UNIT    8'h04
`define USB_VC_PROCESSING_UNIT  8'h05

/* USB Video Streaming Subtype Descriptors */
`define USB_VS_INPUT_HEADER         8'h01
`define USB_VS_OUPUT_HEADER         8'h02
`define USB_VS_STILL_IMAGE_FRAME    8'h03
`define USB_VS_FORMAT_UNCOMPRESSED  8'h04
`define USB_VS_FRAME_UNCOMPRESSED   8'h05
`define USB_VS_FORMAT_MJPEG         8'h06
`define USB_VS_FRAME_MJPEG          8'h07

///* To split numbers into Little Endian format */
//`define WORD_CHARS(x)   (x&8'hff), ((x>>8)&8'hff), ((x>>16)&8'hff), ((x>>24)&8'hff)
//`define SHORT_CHARS(x)  (x&8'hff), ((x>>8)&8'hff)

/* Endpoint Addresses for Video device */
`define VIDEO_STATUS_EP_NUM         8'h01 /* (8'h81) */
`define VIDEO_DATA_EP_NUM           8'h02 /* (8'h82) */

/* Video Class-specific Request codes */
`define SET_CUR     8'h01
`define GET_CUR     8'h81
`define GET_MIN     8'h82
`define GET_MAX     8'h83
`define GET_RES     8'h84
`define GET_LEN     8'h85
`define GET_INFO    8'h86
`define GET_DEF     8'h87

/* Video Streaming Interface Control selectors */
`define VS_PROBE_CONTROL        8'h01
`define VS_COMMIT_CONTROL       8'h02

`define UVC_INTERFACE_BASE	0
`define UVC_VC_INTERFACE	(`UVC_INTERFACE_BASE)
`define UVC_VS_INTERFACE	(`UVC_INTERFACE_BASE + 1)

/* Video Stream related */
`define PAYLOAD_HEADER_LENGTH 8'd12

/* USB Video resolution */
`define BITS_PER_PIXEL  8'd16
/* Guarded so a build can pre-define these before usb_descriptor_video.v pulls
   this file in, which is how the dual-res examples select a different frame
   geometry without a second copy of this tree. Unguarded these would silently
   win over anything set earlier. */
`ifndef WIDTH
`define WIDTH           16'd160
`endif
`ifndef HEIGHT
`define HEIGHT          16'd144
`endif

/* Frame rate */
`define FPS  60
`define FPS_MAX  60
`define FPS_MIN  1

/* Second frame geometry, offered as bFrameIndex 2 alongside WIDTH/HEIGHT as
   bFrameIndex 1. Only present when a build defines UVC_DUAL_RES ahead of this
   file - single-resolution builds see the descriptor and the control block
   exactly as they were, one frame descriptor and no SET_CUR parsing.

   The host chooses between them in SET_CUR(VS_PROBE_CONTROL/VS_COMMIT_CONTROL)
   by bFrameIndex, which ctrl_uvc has to read; see the note there about why it
   ignored SET requests before. */
`ifdef UVC_DUAL_RES
`ifndef WIDTH2
`define WIDTH2          16'd160
`endif
`ifndef HEIGHT2
`define HEIGHT2         16'd144
`endif
`define MAX_FRAME_SIZE2 (`WIDTH2 * `HEIGHT2 * `BITS_PER_PIXEL / 8)
`define MIN_BIT_RATE2   (`MAX_FRAME_SIZE2 * `FPS_MIN * 8)
`define MAX_BIT_RATE2   (`MAX_FRAME_SIZE2 * `FPS_MAX * 8)
`endif

/* THE SOURCE GEOMETRY - what the video input actually delivers, as opposed to
   what the descriptors advertise. With UVC_DUAL_RES the larger WIDTH/HEIGHT is
   an OUTPUT size the restamper produces by replication, and the source is the
   smaller one. Without it the two are the same.

   uvc_restamp is sized from these, so it can be enabled on its own - which is
   how esp32t gets the clock crossing and the pClk colour space converter while
   still emitting 160x144, with the shipping behaviour as the reference. */
`ifdef UVC_DUAL_RES
`define SRC_WIDTH   `WIDTH2
`define SRC_HEIGHT  `HEIGHT2
`else
`define SRC_WIDTH   `WIDTH
`define SRC_HEIGHT  `HEIGHT
`endif

`define MAX_FRAME_SIZE (`WIDTH * `HEIGHT * `BITS_PER_PIXEL / 8)
`define MIN_BIT_RATE   (`MAX_FRAME_SIZE * `FPS_MIN * 8)
`define MAX_BIT_RATE   (`MAX_FRAME_SIZE * `FPS_MAX * 8)
/* Only single packet per mframe supported */
`define PACKET_PER_MFRAME   (2)
/* wMaxPacketSize bits 12:11 = additional transactions per microframe.
   1 => two transactions, giving 2*1012 payload bytes per 125us. */
`define ADDITIONAL_PACKET   (16'd1)
`define PACKET_SIZE    (12'd1024)
`define PAYLOAD_SIZE   (`PACKET_PER_MFRAME * `PACKET_SIZE)
`define DEVICE_CLOCK_FREQUENCY (32'd60000000)

/* Interval defined in 100ns units */
`define FRAME_INTERVAL  (32'd10000000/`FPS)
