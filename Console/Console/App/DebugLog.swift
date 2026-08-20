/// Prints to stdout only in DEBUG builds. In release builds this is a no-op and
/// the string interpolation is never evaluated, so no information leaks to console.
@inline(__always)
func printDebug(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
