//
//  ImageCache.swift
//  Yep
//
//  Created by NIX on 15/3/31.
//  Copyright (c) 2015年 Catch Inc. All rights reserved.
//

import UIKit
import RealmSwift
import MapKit
import Kingfisher

class ImageCache {

    static let sharedInstance = ImageCache()

    let cache = NSCache()
    let cacheQueue = dispatch_queue_create("ImageCacheQueue", DISPATCH_QUEUE_SERIAL)
    let cacheAttachmentQueue = dispatch_queue_create("ImageCacheAttachmentQueue", DISPATCH_QUEUE_SERIAL)
//    let cacheQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)
    
    func imageOfAttachment(attachment: DiscoveredAttachment, withSize: CGSize?, completion: (url: NSURL, image: UIImage?, cacheType: CacheType) -> Void) {

        guard let attachmentURL = NSURL(string: attachment.URLString) else {
            return
        }

        var cacheSize = CGSizeZero
        
        if let withSize = withSize {

            cacheSize = withSize
            
//            let screenScale = UIScreen.mainScreen().scale// * 0.75
//            
//            let deviceSize = CGSizeMake(withSize.width * screenScale, withSize.height * screenScale)
//            
//            cacheSize = deviceSize
        }
        
        let attachmentOriginKey = "y3attachment-0.0-0.0-\(attachmentURL.absoluteString)"

        let attachmentSizeKey = "y3attachment-\(cacheSize.width)-\(cacheSize.height)-\(attachmentURL.absoluteString)"

        println("attachmentSizeKey: \(attachmentSizeKey)")

        let OptionsInfos: KingfisherManager.Options = (forceRefresh: false, lowPriority: false, cacheMemoryOnly: false, shouldDecode: false, queue: cacheAttachmentQueue, scale: UIScreen.mainScreen().scale)
        //查找当前 Size 的 Cache
        
        Kingfisher.ImageCache.defaultCache.retrieveImageForKey(attachmentSizeKey, options: OptionsInfos) { (image, type) -> () in

            if let image = image?.decodedImage() {
                dispatch_async(dispatch_get_main_queue()) {
                    completion(url: attachmentURL, image: image, cacheType: type)
                }

            } else {
                
                //查找原图
                
                Kingfisher.ImageCache.defaultCache.retrieveImageForKey(attachmentOriginKey, options: OptionsInfos) { (image, type) -> () in

                    if let image = image {
                        
                        //裁剪并存储
                        var finalImage = image
                        
                        if cacheSize != CGSizeZero {
                            finalImage = finalImage.scaleToMinSideLength(cacheSize.width)

                            let originalData = UIImageJPEGRepresentation(finalImage, 1.0)
                            //let originalData = UIImagePNGRepresentation(finalImage)
                            Kingfisher.ImageCache.defaultCache.storeImage(finalImage, originalData: originalData, forKey: attachmentSizeKey, toDisk: true, completionHandler: { () -> () in
                            })
                        }
                        
                        dispatch_async(dispatch_get_main_queue()) {
                            completion(url: attachmentURL, image: finalImage, cacheType: type)
                        }
                        
                    } else {
                        
                        // 下载
                        
                        ImageDownloader.defaultDownloader.downloadImageWithURL(attachmentURL, options: OptionsInfos, progressBlock: { receivedSize, totalSize  in
                            
                        }, completionHandler: {  image, error , imageURL, originalData in
                            
                            if let image = image {
                                
                                Kingfisher.ImageCache.defaultCache.storeImage(image, originalData: originalData, forKey: attachmentOriginKey, toDisk: true, completionHandler: nil)
                                
                                var storeImage = image
                                
                                if cacheSize != CGSizeZero {
                                    storeImage = storeImage.scaleToMinSideLength(cacheSize.width)
                                }

                                Kingfisher.ImageCache.defaultCache.storeImage(storeImage,  originalData: UIImageJPEGRepresentation(storeImage, 1.0), forKey: attachmentSizeKey, toDisk: true, completionHandler: nil)
                                
                                let finalImage = storeImage.decodedImage()
                                
                                println("Image Decode size \(storeImage.size)")
                                
                                dispatch_async(dispatch_get_main_queue()) {
                                    completion(url: attachmentURL, image: finalImage, cacheType: .None)
                                }

                            } else {
                                dispatch_async(dispatch_get_main_queue()) {
                                    completion(url: attachmentURL, image: nil, cacheType: .None)
                                }
                            }
                        })
                    }
                }
            }
        }
    }

    func imageOfMessage(message: Message, withSize size: CGSize, tailDirection: MessageImageTailDirection, completion: (loadingProgress: Double, image: UIImage?) -> Void) {

        let imageKey = "image-\(message.messageID)-\(message.localAttachmentName)-\(message.attachmentURLString)"
        // 先看看缓存
        if let image = cache.objectForKey(imageKey) as? UIImage {
            completion(loadingProgress: 1.0, image: image)

        } else {
            let messageID = message.messageID

            var fileName = message.localAttachmentName
            if message.mediaType == MessageMediaType.Video.rawValue {
                fileName = message.localThumbnailName
            }

            var imageURLString = message.attachmentURLString
            if message.mediaType == MessageMediaType.Video.rawValue {
                imageURLString = message.thumbnailURLString
            }
            
            let imageDownloadState = message.downloadState

            let preloadingPropgress: Double = fileName.isEmpty ? 0.01 : 0.5

            // 若可以，先显示 blurredThumbnailImage

            let thumbnailKey = "thumbnail" + imageKey

            if let thumbnail = cache.objectForKey(thumbnailKey) as? UIImage {
                completion(loadingProgress: preloadingPropgress, image: thumbnail)

            } else {
                dispatch_async(self.cacheQueue) {

                    guard let realm = try? Realm() else {
                        return
                    }
                    
                    if let message = messageWithMessageID(messageID, inRealm: realm) {
                        
                        if let blurredThumbnailImage = blurredThumbnailImageOfMessage(message) {
                            let bubbleBlurredThumbnailImage = blurredThumbnailImage.bubbleImageWithTailDirection(tailDirection, size: size).decodedImage()

                            self.cache.setObject(bubbleBlurredThumbnailImage, forKey: thumbnailKey)

                            dispatch_async(dispatch_get_main_queue()) {
                                completion(loadingProgress: preloadingPropgress, image: bubbleBlurredThumbnailImage)
                            }

                        } else {
                            // 或放个默认的图片
                            let defaultImage = tailDirection == .Left ? UIImage(named: "left_tail_image_bubble")! : UIImage(named: "right_tail_image_bubble")!

                            dispatch_async(dispatch_get_main_queue()) {
                                completion(loadingProgress: preloadingPropgress, image: defaultImage)
                            }
                        }
                    }
                }
            }

            dispatch_async(self.cacheQueue) {

                guard let realm = try? Realm() else {
                    return
                }
                
                if imageDownloadState == MessageDownloadState.Downloaded.rawValue {
                
                    if !fileName.isEmpty {
                        if
                            let imageFileURL = NSFileManager.yepMessageImageURLWithName(fileName),
                            let image = UIImage(contentsOfFile: imageFileURL.path!) {
                                
                                let messageImage = image.bubbleImageWithTailDirection(tailDirection, size: size).decodedImage()
                                
                                self.cache.setObject(messageImage, forKey: imageKey)
                                
                                dispatch_async(dispatch_get_main_queue()) {
                                    completion(loadingProgress: 1.0, image: messageImage)
                                }
                                
                                return
                        }
                    }
                }

                // 下载

                if imageURLString.isEmpty {
                    dispatch_async(dispatch_get_main_queue()) {
                        completion(loadingProgress: 1.0, image: nil)
                    }

                    return
                }

                if let message = messageWithMessageID(messageID, inRealm: realm) {

                    let mediaType = message.mediaType

                    YepDownloader.downloadAttachmentsOfMessage(message, reportProgress: { progress in
                        dispatch_async(dispatch_get_main_queue()) {
                            completion(loadingProgress: progress, image: nil)
                        }

                    }, imageFinished: { image in

                        let messageImage = image.bubbleImageWithTailDirection(tailDirection, size: size).decodedImage()

                        self.cache.setObject(messageImage, forKey: imageKey)

                        dispatch_async(dispatch_get_main_queue()) {
                            if mediaType == MessageMediaType.Image.rawValue {
                                completion(loadingProgress: 1.0, image: messageImage)

                            } else { // 视频的封面图片，要保障设置到
                                completion(loadingProgress: 1.5, image: messageImage)
                            }
                        }
                    })

                } else {
                    dispatch_async(dispatch_get_main_queue()) {
                        completion(loadingProgress: 1.0, image: nil)
                    }
                }
            }
        }
    }

    func mapImageOfMessage(message: Message, withSize size: CGSize, tailDirection: MessageImageTailDirection, bottomShadowEnabled: Bool, completion: (UIImage) -> ()) {

        let imageKey = "mapImage-\(message.coordinate)"

        // 先看看缓存
        if let image = cache.objectForKey(imageKey) as? UIImage {
            completion(image)

        } else {

            if let coordinate = message.coordinate {

                // 先放个默认的图片

                let fileName = message.localAttachmentName

                // 再保证一次，防止旧消息导致错误
                let latitude: CLLocationDegrees = coordinate.safeLatitude
                let longitude: CLLocationDegrees = coordinate.safeLongitude

                dispatch_async(self.cacheQueue) {

                    // 再看看是否已有地图图片文件

                    if !fileName.isEmpty {
                        if
                            let imageFileURL = NSFileManager.yepMessageImageURLWithName(fileName),
                            let image = UIImage(contentsOfFile: imageFileURL.path!) {

                                let mapImage = image.bubbleImageWithTailDirection(tailDirection, size: size, forMap: bottomShadowEnabled).decodedImage()

                                self.cache.setObject(mapImage, forKey: imageKey)

                                dispatch_async(dispatch_get_main_queue()) {
                                    completion(mapImage)
                                }

                                return
                        }
                    }
                    
                    let defaultImage = tailDirection == .Left ? UIImage(named: "left_tail_image_bubble")! : UIImage(named: "right_tail_image_bubble")!
                    completion(defaultImage)    

                    // 没有地图图片文件，只能生成了

                    let options = MKMapSnapshotOptions()
                    options.scale = UIScreen.mainScreen().scale
                    options.size = size

                    let locationCoordinate = CLLocationCoordinate2DMake(latitude, longitude)
                    options.region = MKCoordinateRegionMakeWithDistance(locationCoordinate, 500, 500)

                    let mapSnapshotter = MKMapSnapshotter(options: options)

                    mapSnapshotter.startWithCompletionHandler { (snapshot, error) -> Void in
                        if error == nil {

                            guard let snapshot = snapshot else {
                                return
                            }

                            let image = snapshot.image
                            
                            UIGraphicsBeginImageContextWithOptions(image.size, true, image.scale)

                            let pinImage = UIImage(named: "icon_current_location")!

                            image.drawAtPoint(CGPointZero)

                            let pinCenter = snapshot.pointForCoordinate(locationCoordinate)

                            let xOffset: CGFloat
                            switch tailDirection {
                            case .Left:
                                xOffset = 3
                            case .Right:
                                xOffset = -3
                            }

                            let pinOrigin = CGPoint(x: pinCenter.x - pinImage.size.width * 0.5 + xOffset, y: pinCenter.y - pinImage.size.height * 0.5)
                            pinImage.drawAtPoint(pinOrigin)

                            let finalImage = UIGraphicsGetImageFromCurrentImageContext()

                            UIGraphicsEndImageContext()

                            // save it

                            if let data = UIImageJPEGRepresentation(finalImage, 1.0) {

                                let fileName = NSUUID().UUIDString

                                if let _ = NSFileManager.saveMessageImageData(data, withName: fileName) {

                                    dispatch_async(dispatch_get_main_queue()) {
                                        
                                        if let realm = message.realm {
                                            let _ = try? realm.write {
                                                message.localAttachmentName = fileName
                                            }
                                        }
                                    }
                                }
                            }

                            let mapImage = finalImage.bubbleImageWithTailDirection(tailDirection, size: size, forMap: bottomShadowEnabled).decodedImage()

                            self.cache.setObject(mapImage, forKey: imageKey)

                            dispatch_async(dispatch_get_main_queue()) {
                                completion(mapImage)
                            }
                        }
                    }
                }
            }
        }
    }

    func mapImageOfLocationCoordinate(locationCoordinate: CLLocationCoordinate2D, withSize size: CGSize, completion: (UIImage) -> ()) {

        let imageKey = "feedMapImage-\(size)-\(locationCoordinate)"

        // 先看看缓存
        if let image = cache.objectForKey(imageKey) as? UIImage {
            completion(image)

        } else {
            let options = MKMapSnapshotOptions()
            options.scale = UIScreen.mainScreen().scale
            let size = size
            options.size = size
            options.region = MKCoordinateRegionMakeWithDistance(locationCoordinate, 500, 500)

            let mapSnapshotter = MKMapSnapshotter(options: options)

            mapSnapshotter.startWithQueue(cacheQueue, completionHandler: { snapshot, error in
                if error == nil {

                    guard let snapshot = snapshot else {
                        return
                    }

                    let image = snapshot.image

                    self.cache.setObject(image, forKey: imageKey)

                    dispatch_async(dispatch_get_main_queue()) {
                        completion(image)
                    }
                }
            })
        }
    }
}

