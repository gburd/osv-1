//! Crucible block device driver for OSv.
//!
//! This crate implements an OSv block device driver backed by
//! Oxide's Crucible distributed storage system. It exposes a
//! C FFI surface that the OSv kernel calls through the standard
//! `devops` function-pointer table.
//!
//! Build with `--features kernel` (default) for `no_std` mode
//! suitable for linking into the OSv kernel image.

#![cfg_attr(feature = "kernel", no_std)]
#![allow(non_upper_case_globals)]

// FFI entry points called from the OSv kernel.
//
// These stubs will be filled in by task #9 (Implement Crucible
// block device driver). For now they return ENODEV so the
// driver can be loaded without crashing.

const ENODEV: core::ffi::c_int = 19;

#[no_mangle]
pub extern "C" fn crucible_init() -> core::ffi::c_int {
    0
}

#[no_mangle]
pub extern "C" fn crucible_open(
    _dev: *mut osv_sys::device,
    _flags: core::ffi::c_int,
) -> core::ffi::c_int {
    ENODEV
}

#[no_mangle]
pub extern "C" fn crucible_close(_dev: *mut osv_sys::device) -> core::ffi::c_int {
    ENODEV
}

#[no_mangle]
pub extern "C" fn crucible_read(
    _dev: *mut osv_sys::device,
    _uio: *mut osv_sys::uio,
    _ioflags: core::ffi::c_int,
) -> core::ffi::c_int {
    ENODEV
}

#[no_mangle]
pub extern "C" fn crucible_write(
    _dev: *mut osv_sys::device,
    _uio: *mut osv_sys::uio,
    _ioflags: core::ffi::c_int,
) -> core::ffi::c_int {
    ENODEV
}

#[no_mangle]
pub extern "C" fn crucible_ioctl(
    _dev: *mut osv_sys::device,
    _cmd: core::ffi::c_ulong,
    _arg: *mut core::ffi::c_void,
) -> core::ffi::c_int {
    ENODEV
}

#[no_mangle]
pub extern "C" fn crucible_strategy(_bio: *mut osv_sys::bio) {
    // Will be implemented in task #9
}

/// Panic handler required for no_std builds.
#[cfg(feature = "kernel")]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}
