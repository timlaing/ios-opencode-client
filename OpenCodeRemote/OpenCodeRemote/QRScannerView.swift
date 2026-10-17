import SwiftUI
import Vision
import VisionKit

/// Camera scanning for the existing `opencode pair` QR payload — the default
/// S03 path (docs/navigation-screens.md). Wraps VisionKit's data scanner; the
/// app targets iOS 18, so no availability guard is needed.
///
/// The simulator has no camera, so callers must check `isSupported` and direct
/// the user to the manual fallback. Scanning is passive: the payload is handed
/// back for parsing and review, and nothing is redeemed or contacted here
/// (docs/implementation-guide.md: no commands execute on scanning).
struct QRScannerView: UIViewControllerRepresentable {
    /// Called once per newly recognized QR payload string.
    var onScan: (String) -> Void
    /// Called when scanning becomes unavailable (permission denied, no camera).
    var onUnavailable: (String) -> Void

    /// False on the simulator and camera-less hardware; S03 shows the manual
    /// fallback in that case.
    static var isSupported: Bool { DataScannerViewController.isSupported }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            // Only QR: the pairing contract accepts no other payload shape.
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onUnavailable: onUnavailable)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private let onUnavailable: (String) -> Void
        private var lastPayload: String?

        init(onScan: @escaping (String) -> Void, onUnavailable: @escaping (String) -> Void) {
            self.onScan = onScan
            self.onUnavailable = onUnavailable
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue,
                      payload != lastPayload else { continue }
                lastPayload = payload
                onScan(payload)
                return
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            switch error {
            case .cameraRestricted:
                onUnavailable("Camera access is restricted on this device. Allow camera access in Settings to scan pairing codes.")
            case .unsupported:
                onUnavailable("The camera can't be used for scanning right now.")
            @unknown default:
                onUnavailable("The camera can't be used for scanning right now.")
            }
        }
    }
}
