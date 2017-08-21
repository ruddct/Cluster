//
//  Cluster.swift
//  Cluster
//
//  Created by Lasha Efremidze on 4/13/17.
//  Copyright © 2017 efremidze. All rights reserved.
//

import CoreLocation
import MapKit

open class ClusterManager {
    private let dispatchQueue = DispatchQueue(label: "cluster", qos: .background, attributes: [], autoreleaseFrequency: .inherit, target: nil)
    private var isComputingClustering = false
    var tree = QuadTree(rect: MKMapRectWorld)
    
    /**
     Controls the level from which clustering will be enabled. Min value is 2 (max zoom out), max is 20 (max zoom in).
     */
    open var zoomLevel: Int = 20 {
        didSet {
            zoomLevel = zoomLevel.clamped(to: 2...20)
        }
    }
    
    /**
     The minimum number of annotations for a cluster.
     */
    open var minimumCountForCluster: Int = 2
    
    /**
     Whether to remove invisible annotations.
     */
    open var shouldRemoveInvisibleAnnotations: Bool = true
    
    public init() {}
    
    /**
     Adds an annotation object to the cluster manager.
     
     - Parameters:
        - annotation: An annotation object. The object must conform to the MKAnnotation protocol.
     */
    open func add(_ annotation: MKAnnotation) {
        tree.add(annotation)
    }
    
    /**
     Adds an array of annotation objects to the cluster manager.
     
     - Parameters:
        - annotations: An array of annotation objects. Each object in the array must conform to the MKAnnotation protocol.
     */
    open func add(_ annotations: [MKAnnotation]) {
        for annotation in annotations {
            add(annotation)
        }
    }
    
    /**
     Removes an annotation object from the cluster manager.
     
     - Parameters:
        - annotation: An annotation object. The object must conform to the MKAnnotation protocol.
     */
    open func remove(_ annotation: MKAnnotation) {
        tree.remove(annotation)
    }
    
    /**
     Removes an array of annotation objects from the cluster manager.
     
     - Parameters:
        - annotations: An array of annotation objects. Each object in the array must conform to the MKAnnotation protocol.
     */
    open func remove(_ annotations: [MKAnnotation]) {
        for annotation in annotations {
            remove(annotation)
        }
    }
    
    /**
     Removes all the annotation objects from the cluster manager.
     */
    open func removeAll() {
        tree = QuadTree(rect: MKMapRectWorld)
    }
    
    /**
     The list of annotations associated.
     
     The objects in this array must adopt the MKAnnotation protocol. If no annotations are associated with the cluster manager, the value of this property is an empty array.
     */
    open var annotations: [MKAnnotation] {
        return tree.annotations(in: MKMapRectWorld)
    }
    
    /**
     The list of visible annotations associated.
     */
    public var visibleAnnotations = Set<NSObject>()
    
    /**
     Reload the annotations on the map view.
     
     - Parameters:
        - mapView: The map view object to reload.
     */
    
    open func reload(_ mapView: MKMapView, visibleMapRect: MKMapRect) {
        UserDefaults.standard.setValue(false, forKey: "_UIConstraintBasedLayoutLogUnsatisfiable")
        let zoomScale = ZoomScale(mapView.bounds.width) / visibleMapRect.size.width
        guard !isComputingClustering else { return }
        self.isComputingClustering = true
        self.dispatchQueue.async {
            let (toAdd, toRemove) = self.clusteredAnnotations(mapView, zoomScale: zoomScale, visibleMapRect: visibleMapRect)
            DispatchQueue.main.async {
                mapView.removeAnnotations(toRemove)
                mapView.addAnnotations(toAdd)
                self.visibleAnnotations.subtract(Set(toRemove as! [NSObject]))
                self.visibleAnnotations.formUnion(Set(toAdd as! [NSObject]))
                self.isComputingClustering = false
            }
        }
    }
    
    func clusteredAnnotations(_ mapView: MKMapView, zoomScale: ZoomScale, visibleMapRect: MKMapRect) -> (toAdd: [MKAnnotation], toRemove: [MKAnnotation]) {
        guard !zoomScale.isInfinite else { return (toAdd: [], toRemove: []) }
        
        let zoomLevel = zoomScale.zoomLevel()
        let cellSize = zoomLevel.cellSize()
        let scaleFactor = zoomScale / cellSize
        
        let minX = Int(floor(visibleMapRect.minX * scaleFactor))
        let maxX = Int(floor(visibleMapRect.maxX * scaleFactor))
        let minY = Int(floor(visibleMapRect.minY * scaleFactor))
        let maxY = Int(floor(visibleMapRect.maxY * scaleFactor))
        
        var clusteredAnnotations = [MKAnnotation]()
        var visibleClusters = [CLLocationCoordinate2D: MKAnnotation]() // Used so we don't remove/re-add clusters that are already on the map
        self.visibleAnnotations
            .flatMap({ return $0 as? ClusterAnnotation })
            .forEach {
                visibleClusters[$0.coordinate] = $0
        }
        for x in minX...maxX {
            for y in minY...maxY {
                var mapRect = MKMapRect(x: Double(x) / scaleFactor, y: Double(y) / scaleFactor, width: 1 / scaleFactor, height: 1 / scaleFactor)
                if mapRect.origin.x > MKMapPointMax.x {
                    mapRect.origin.x -= MKMapPointMax.x
                }
                
                var totalLatitude: Double = 0
                var totalLongitude: Double = 0
                var annotations = [MKAnnotation]()
                var hash = [CLLocationCoordinate2D: [MKAnnotation]]()
                
                for node in tree.annotations(in: mapRect) {
                    totalLatitude += node.coordinate.latitude
                    totalLongitude += node.coordinate.longitude
                    annotations.append(node)
                    hash[node.coordinate, default: [MKAnnotation]()] += [node]
                }
                
                for value in hash.values {
                    for (index, node) in value.enumerated() {
                        let distanceFromContestedLocation = 3 * Double(value.count) / 2
                        let radiansBetweenAnnotations = (.pi * 2) / Double(value.count)
                        let bearing = radiansBetweenAnnotations * Double(index)
                        (node as? Annotation)?.coordinate = node.coordinate.coordinate(onBearingInRadians: bearing, atDistanceInMeters: distanceFromContestedLocation)
                    }
                }
                
                let count = annotations.count
                if count >= minimumCountForCluster, Int(zoomLevel) <= self.zoomLevel {
                    let coordinate = CLLocationCoordinate2D(
                        latitude: CLLocationDegrees(totalLatitude) / CLLocationDegrees(count),
                        longitude: CLLocationDegrees(totalLongitude) / CLLocationDegrees(count)
                    )
                    var cluster = (visibleClusters[coordinate] as? ClusterAnnotation) ?? ClusterAnnotation()
                    cluster.coordinate = coordinate
                    cluster.annotations = annotations
                    cluster.type = (annotations.first as? Annotation)?.type
                    clusteredAnnotations.append(cluster)
                } else {
                    clusteredAnnotations += annotations
                }
            }
        }
        
        let before = Set(self.visibleAnnotations)
        let after = Set(clusteredAnnotations as! [NSObject])
        
        var toRemove = before.subtracting(after)
        let toAdd = after.subtracting(before)
        
        if !shouldRemoveInvisibleAnnotations {
            let nonRemoving = toRemove.filter { !visibleMapRect.contains(($0 as AnyObject).coordinate) }
            toRemove.subtract(Set(nonRemoving))
        }
        
        return (toAdd: Array(toAdd) as! [MKAnnotation], toRemove: Array(toRemove) as! [MKAnnotation])
    }
}

