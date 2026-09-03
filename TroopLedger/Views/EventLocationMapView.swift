import MapKit
import SwiftUI

struct EventLocationMapView: View {
    let query: String
    let displayName: String

    @State private var mapItem: MKMapItem?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isSearching = false
    @State private var searchFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let mapItem {
                Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                    Marker(displayName.nonempty ?? mapItem.name ?? "Event location", coordinate: mapItem.placemark.coordinate)
                }
                .mapStyle(.standard(elevation: .realistic))
                .frame(minHeight: 210)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.quaternary, lineWidth: 1)
                }

                HStack {
                    Label("Map location", systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open in Apple Maps", systemImage: "arrow.up.right.square") {
                        mapItem.openInMaps()
                    }
                }
            } else if isSearching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding this location in Apple Maps…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            } else if searchFailed, let mapsURL {
                HStack {
                    Label("A map preview could not be loaded.", systemImage: "map")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("Search Apple Maps", destination: mapsURL)
                }
                .frame(minHeight: 44)
            }
        }
        .task(id: query) { await findLocation() }
    }

    @MainActor
    private func findLocation() async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            mapItem = nil
            searchFailed = false
            return
        }

        isSearching = true
        searchFailed = false
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmedQuery

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return }
            mapItem = response.mapItems.first
            if let coordinate = mapItem?.placemark.coordinate {
                cameraPosition = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                ))
            }
            searchFailed = mapItem == nil
        } catch {
            guard !Task.isCancelled else { return }
            mapItem = nil
            searchFailed = true
        }
        isSearching = false
    }

    private var mapsURL: URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

private extension String {
    var nonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
