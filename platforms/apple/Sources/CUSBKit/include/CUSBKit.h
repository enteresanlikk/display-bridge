#ifndef CUSBKit_h
#define CUSBKit_h

#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

// Opaque handle typedefs for Swift interop
// Using Interface190 for ClearPipeStallBothEnds support (available since macOS 10.2.3).
typedef IOUSBDeviceInterface182  **CUSBDeviceRef;
typedef IOUSBInterfaceInterface190 **CUSBInterfaceRef;

// MARK: - Device operations

/// Creates a device interface from an IOKit service.
IOReturn CUSBCreateDeviceInterface(io_service_t service, CUSBDeviceRef *outDevice);

/// Opens the device for exclusive access.
IOReturn CUSBDeviceOpen(CUSBDeviceRef device);

/// Closes the device (USBDeviceClose + Release). Only call if device was opened.
void CUSBDeviceClose(CUSBDeviceRef device);

/// Releases the device interface without calling USBDeviceClose.
/// Use for device interfaces that were never opened with CUSBDeviceOpen.
void CUSBDeviceRelease(CUSBDeviceRef device);

/// Returns the device vendor ID.
IOReturn CUSBGetDeviceVendor(CUSBDeviceRef device, UInt16 *outVendor);

/// Returns the device product ID.
IOReturn CUSBGetDeviceProduct(CUSBDeviceRef device, UInt16 *outProduct);

/// Sends a control request to the device.
IOReturn CUSBDeviceControlRequest(CUSBDeviceRef device,
                                  UInt8  bmRequestType,
                                  UInt8  bRequest,
                                  UInt16 wValue,
                                  UInt16 wIndex,
                                  void  *pData,
                                  UInt16 wLength,
                                  UInt32 *outLengthTransferred);

/// Re-enumerates (resets) the device on the bus.
IOReturn CUSBDeviceReEnumerate(CUSBDeviceRef device, UInt32 options);

// MARK: - Interface operations

/// Finds the first interface of a USB device and creates an interface handle.
/// The device must remain open for I/O — outDevice receives the opened device handle
/// that the caller must close with CUSBDeviceClose when done.
IOReturn CUSBCreateInterfaceInterface(io_service_t deviceService,
                                      CUSBInterfaceRef *outInterface,
                                      CUSBDeviceRef *outDevice);

/// Opens the interface for I/O.
IOReturn CUSBInterfaceOpen(CUSBInterfaceRef interface);

/// Closes the interface.
void CUSBInterfaceClose(CUSBInterfaceRef interface);

/// Returns the number of endpoints on the interface.
IOReturn CUSBGetNumEndpoints(CUSBInterfaceRef interface, UInt8 *outNum);

/// Returns endpoint properties for a given pipe index (1-based).
IOReturn CUSBGetEndpointInfo(CUSBInterfaceRef interface,
                             UInt8  pipeIndex,
                             UInt8  *outDirection,
                             UInt8  *outTransferType,
                             UInt16 *outMaxPacketSize);

// MARK: - Bulk transfer

/// Synchronous bulk read.
IOReturn CUSBReadPipe(CUSBInterfaceRef interface,
                      UInt8  pipeIndex,
                      void   *buffer,
                      UInt32 *length);

/// Synchronous bulk read with timeout (milliseconds).
/// noDataTimeout: abort if no data moves within this time.
/// completionTimeout: abort if entire read doesn't finish within this time.
IOReturn CUSBReadPipeTO(CUSBInterfaceRef interface,
                        UInt8  pipeIndex,
                        void   *buffer,
                        UInt32 *length,
                        UInt32 noDataTimeout,
                        UInt32 completionTimeout);

/// Synchronous bulk write.
IOReturn CUSBWritePipe(CUSBInterfaceRef interface,
                       UInt8  pipeIndex,
                       void   *buffer,
                       UInt32 length);

/// Synchronous bulk write with timeout (milliseconds).
/// noDataTimeout: abort if no data moves within this time.
/// completionTimeout: abort if entire write doesn't finish within this time.
IOReturn CUSBWritePipeTO(CUSBInterfaceRef interface,
                         UInt8  pipeIndex,
                         void   *buffer,
                         UInt32 length,
                         UInt32 noDataTimeout,
                         UInt32 completionTimeout);

/// Callback type for async writes.
typedef void (*CUSBWriteCallback)(void *refcon, IOReturn result, void *arg0);

/// Asynchronous bulk write with completion callback.
IOReturn CUSBWritePipeAsync(CUSBInterfaceRef interface,
                            UInt8            pipeIndex,
                            void            *buffer,
                            UInt32           length,
                            CUSBWriteCallback callback,
                            void            *refcon);

/// Creates a CFRunLoopSource for async I/O callbacks.
IOReturn CUSBCreateAsyncEventSource(CUSBInterfaceRef interface,
                                    CFRunLoopSourceRef *outSource);

/// Aborts all pending I/O on a pipe.
IOReturn CUSBAbortPipe(CUSBInterfaceRef interface, UInt8 pipeIndex);

/// Clears a stall condition on both host and device sides.
/// Sends CLEAR_FEATURE(ENDPOINT_HALT) to device + resets host data toggle.
IOReturn CUSBClearPipeStallBothEnds(CUSBInterfaceRef interface, UInt8 pipeIndex);

/// Returns the pipe's max packet size (useful for debugging USB speed).
IOReturn CUSBGetPipeMaxPacketSize(CUSBInterfaceRef interface, UInt8 pipeIndex, UInt16 *outMaxPacketSize);

#endif /* CUSBKit_h */
