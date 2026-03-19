#include "CUSBKit.h"

// MARK: - Device operations

IOReturn CUSBCreateDeviceInterface(io_service_t service, CUSBDeviceRef *outDevice) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;

    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service,
        kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );
    if (kr != kIOReturnSuccess || plugin == NULL) {
        return kr != kIOReturnSuccess ? kr : kIOReturnNoResources;
    }

    HRESULT hr = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID182),
        (LPVOID *)outDevice
    );
    (*plugin)->Release(plugin);

    return (hr == S_OK) ? kIOReturnSuccess : kIOReturnNoResources;
}

IOReturn CUSBDeviceOpen(CUSBDeviceRef device) {
    return (*device)->USBDeviceOpen(device);
}

void CUSBDeviceClose(CUSBDeviceRef device) {
    (*device)->USBDeviceClose(device);
    (*device)->Release(device);
}

void CUSBDeviceRelease(CUSBDeviceRef device) {
    (*device)->Release(device);
}

IOReturn CUSBGetDeviceVendor(CUSBDeviceRef device, UInt16 *outVendor) {
    return (*device)->GetDeviceVendor(device, outVendor);
}

IOReturn CUSBGetDeviceProduct(CUSBDeviceRef device, UInt16 *outProduct) {
    return (*device)->GetDeviceProduct(device, outProduct);
}

IOReturn CUSBDeviceControlRequest(CUSBDeviceRef device,
                                  UInt8  bmRequestType,
                                  UInt8  bRequest,
                                  UInt16 wValue,
                                  UInt16 wIndex,
                                  void  *pData,
                                  UInt16 wLength,
                                  UInt32 *outLengthTransferred) {
    IOUSBDevRequest req;
    req.bmRequestType = bmRequestType;
    req.bRequest = bRequest;
    req.wValue = wValue;
    req.wIndex = wIndex;
    req.pData = pData;
    req.wLength = wLength;
    req.wLenDone = 0;

    IOReturn ret = (*device)->DeviceRequest(device, &req);
    if (outLengthTransferred != NULL) {
        *outLengthTransferred = req.wLenDone;
    }
    return ret;
}

IOReturn CUSBDeviceReEnumerate(CUSBDeviceRef device, UInt32 options) {
    return (*device)->ResetDevice(device);
}

// MARK: - Interface operations

IOReturn CUSBCreateInterfaceInterface(io_service_t deviceService,
                                      CUSBInterfaceRef *outInterface,
                                      CUSBDeviceRef *outDevice) {
    // First create a device interface to set up interface request
    CUSBDeviceRef device = NULL;
    IOReturn ret = CUSBCreateDeviceInterface(deviceService, &device);
    if (ret != kIOReturnSuccess) return ret;

    ret = (*device)->USBDeviceOpen(device);
    if (ret != kIOReturnSuccess) {
        (*device)->Release(device);
        return ret;
    }

    // SET_CONFIGURATION is REQUIRED by the Android AOA protocol.
    // Without it, f_accessory's acc_function_set_alt() is never called,
    // dev->online stays 0, and bulk endpoints are never enabled —
    // causing acc_read() to block forever after the first hardware-buffered packet.
    IOUSBConfigurationDescriptorPtr config = NULL;
    ret = (*device)->GetConfigurationDescriptorPtr(device, 0, &config);
    if (ret == kIOReturnSuccess && config != NULL) {
        (*device)->SetConfiguration(device, config->bConfigurationValue);
    }

    // Create an iterator over the device's interfaces
    IOUSBFindInterfaceRequest ifRequest;
    ifRequest.bInterfaceClass    = kIOUSBFindInterfaceDontCare;
    ifRequest.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    ifRequest.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    ifRequest.bAlternateSetting  = kIOUSBFindInterfaceDontCare;

    io_iterator_t iterator = 0;
    ret = (*device)->CreateInterfaceIterator(device, &ifRequest, &iterator);
    if (ret != kIOReturnSuccess) {
        (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        return ret;
    }

    // Grab the first interface
    io_service_t ifService = IOIteratorNext(iterator);
    IOObjectRelease(iterator);

    if (ifService == 0) {
        (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        return kIOReturnNotFound;
    }

    // Create plugin for the interface
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    ret = IOCreatePlugInInterfaceForService(
        ifService,
        kIOUSBInterfaceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );
    IOObjectRelease(ifService);

    if (ret != kIOReturnSuccess || plugin == NULL) {
        (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        return ret != kIOReturnSuccess ? ret : kIOReturnNoResources;
    }

    HRESULT hr = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID190),
        (LPVOID *)outInterface
    );
    (*plugin)->Release(plugin);

    if (hr != S_OK) {
        (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        return kIOReturnNoResources;
    }

    // Return the opened device handle — caller must keep it alive for I/O
    if (outDevice != NULL) {
        *outDevice = device;
    }

    return kIOReturnSuccess;
}

IOReturn CUSBInterfaceOpen(CUSBInterfaceRef interface) {
    return (*interface)->USBInterfaceOpen(interface);
}

void CUSBInterfaceClose(CUSBInterfaceRef interface) {
    (*interface)->USBInterfaceClose(interface);
    (*interface)->Release(interface);
}

IOReturn CUSBGetNumEndpoints(CUSBInterfaceRef interface, UInt8 *outNum) {
    return (*interface)->GetNumEndpoints(interface, outNum);
}

IOReturn CUSBGetEndpointInfo(CUSBInterfaceRef interface,
                             UInt8  pipeIndex,
                             UInt8  *outDirection,
                             UInt8  *outTransferType,
                             UInt16 *outMaxPacketSize) {
    UInt8 direction = 0, number = 0, transferType = 0, interval = 0;
    UInt16 maxPacketSize = 0;

    IOReturn ret = (*interface)->GetPipeProperties(
        interface, pipeIndex,
        &direction, &number, &transferType, &maxPacketSize, &interval
    );

    if (ret == kIOReturnSuccess) {
        if (outDirection)     *outDirection     = direction;
        if (outTransferType)  *outTransferType  = transferType;
        if (outMaxPacketSize) *outMaxPacketSize = maxPacketSize;
    }
    return ret;
}

// MARK: - Bulk transfer

IOReturn CUSBReadPipe(CUSBInterfaceRef interface,
                      UInt8  pipeIndex,
                      void   *buffer,
                      UInt32 *length) {
    return (*interface)->ReadPipe(interface, pipeIndex, buffer, length);
}

IOReturn CUSBReadPipeTO(CUSBInterfaceRef interface,
                         UInt8  pipeIndex,
                         void   *buffer,
                         UInt32 *length,
                         UInt32 noDataTimeout,
                         UInt32 completionTimeout) {
    return (*interface)->ReadPipeTO(interface, pipeIndex, buffer, length,
                                    noDataTimeout, completionTimeout);
}

IOReturn CUSBWritePipe(CUSBInterfaceRef interface,
                       UInt8  pipeIndex,
                       void   *buffer,
                       UInt32 length) {
    return (*interface)->WritePipe(interface, pipeIndex, buffer, length);
}

IOReturn CUSBWritePipeTO(CUSBInterfaceRef interface,
                         UInt8  pipeIndex,
                         void   *buffer,
                         UInt32 length,
                         UInt32 noDataTimeout,
                         UInt32 completionTimeout) {
    return (*interface)->WritePipeTO(interface, pipeIndex, buffer, length,
                                     noDataTimeout, completionTimeout);
}

IOReturn CUSBWritePipeAsync(CUSBInterfaceRef interface,
                            UInt8            pipeIndex,
                            void            *buffer,
                            UInt32           length,
                            CUSBWriteCallback callback,
                            void            *refcon) {
    return (*interface)->WritePipeAsync(interface, pipeIndex, buffer, length,
                                       (IOAsyncCallback1)callback, refcon);
}

IOReturn CUSBCreateAsyncEventSource(CUSBInterfaceRef interface,
                                    CFRunLoopSourceRef *outSource) {
    return (*interface)->CreateInterfaceAsyncEventSource(interface, outSource);
}

IOReturn CUSBAbortPipe(CUSBInterfaceRef interface, UInt8 pipeIndex) {
    return (*interface)->AbortPipe(interface, pipeIndex);
}

IOReturn CUSBClearPipeStallBothEnds(CUSBInterfaceRef interface, UInt8 pipeIndex) {
    return (*interface)->ClearPipeStallBothEnds(interface, pipeIndex);
}

IOReturn CUSBGetPipeMaxPacketSize(CUSBInterfaceRef interface, UInt8 pipeIndex, UInt16 *outMaxPacketSize) {
    UInt8 direction = 0, number = 0, transferType = 0, interval = 0;
    UInt16 maxPacketSize = 0;

    IOReturn ret = (*interface)->GetPipeProperties(
        interface, pipeIndex,
        &direction, &number, &transferType, &maxPacketSize, &interval
    );

    if (ret == kIOReturnSuccess && outMaxPacketSize != NULL) {
        *outMaxPacketSize = maxPacketSize;
    }
    return ret;
}
