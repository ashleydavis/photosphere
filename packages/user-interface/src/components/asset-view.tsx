import React, { useEffect, useState } from "react";
import { AssetInfo } from "../pages/gallery/components/asset-info";
import { useGalleryItem } from "../context/gallery-item-context";
import { Image } from "./image";
import { Video } from "./video";
import { useGallery } from "../context/gallery-context";
import { Drawer } from "@mui/joy";
import { Swiper, SwiperSlide } from 'swiper/react';
import 'swiper/css';
import 'swiper/css/navigation';
import 'swiper/css/pagination';

import { Zoom, Navigation, Pagination, Mousewheel, Keyboard } from 'swiper/modules';

function Swipey() {
    return (
        <Swiper
            style={{
                '--swiper-navigation-color': '#fff',
                '--swiper-pagination-color': '#fff',
                position: 'fixed',
                top: 0,
                left: 0,
                right: 0,
                bottom: 0,
            }}
            cssMode={true}
            navigation={true}
            pagination={{
                clickable: true,
            }}
            mousewheel={true}
            keyboard={true}
            modules={[Navigation, Pagination, Mousewheel, Keyboard]}
            className="mySwiper"
        >
            <SwiperSlide>
                <div>
                    <img src="https://swiperjs.com/demos/images/nature-1.jpg" />
                </div>
            </SwiperSlide>
            <SwiperSlide>
                <div>
                    <img src="https://swiperjs.com/demos/images/nature-2.jpg" />
                </div>
            </SwiperSlide>
            <SwiperSlide>
                <div>
                    <img src="https://swiperjs.com/demos/images/nature-3.jpg" />
                </div>
            </SwiperSlide>
            <SwiperSlide>
                <div>
                    <img src="https://swiperjs.com/demos/images/nature-4.jpg" />
                </div>
            </SwiperSlide>
            <SwiperSlide>
                <div>
                    <img src="https://swiperjs.com/demos/images/nature-5.jpg" />
                </div>
            </SwiperSlide>
            <SwiperSlide>
                <div>
                    <img src="https://swiperjs.com/demos/images/nature-6.jpg" />
                </div>
            </SwiperSlide>
            <SwiperSlide>
                <div>
                    <img src="https://swiperjs.com/demos/images/nature-7.jpg" />
                </div>
            </SwiperSlide>
            <SwiperSlide>
                <div>
                    <img src="https://swiperjs.com/demos/images/nature-8.jpg" />
                </div>
            </SwiperSlide>
            <SwiperSlide>
                <div>
                    <img src="https://swiperjs.com/demos/images/nature-9.jpg" />
                </div>
            </SwiperSlide>
        </Swiper>
    );
};


export interface IAssetViewProps { 

    //
    // Event raised when the model is closed.
    //
    onClose: () => void;

    //
    // Event raised to move to the next asset in the gallery.
    //
    onNext: () => void;

    //
    // Event raised to move to the previous asset in the gallery.
    //
    onPrev: () => void;
}

//
// Shows info for a particular asset.
//
export function AssetView({ onClose, onNext, onPrev }: IAssetViewProps) {

    const { getNext, getPrev } = useGallery();
    const { asset } = useGalleryItem();

    // 
    // Set to true to open the info modal.
    //
    const [openInfo, setOpenInfo] = useState<boolean>(false);

    if (!asset) {
        return null; // Waiting for asset to be loaded.
    }

    return (
        <Swipey />
    //     <div className="photo text-xl">
    //         <div className="w-full h-full flex flex-col justify-center items-center">
    //             <div className="photo-container flex flex-col items-center justify-center">
    //                 {asset.contentType.startsWith("video/")
    //                     && <Video
    //                         asset={asset}
    //                         />
    //                     || <Image                                
    //                         asset={asset}
    //                         />
    //                 }
    //             </div>

    //             <div className="photo-nav w-full h-full flex flex-row pointer-events-none">
    //                 {getPrev(asset) !== undefined
    //                     && <div className="flex flex-col justify-center">
    //                         <button
    //                             className="ml-4 p-1 px-3 pointer-events-auto rounded border border-solid border-white"
    //                             onClick={() => onPrev()}
    //                             >
    //                             <i className="fa-solid fa-arrow-left"></i>
    //                         </button>
    //                     </div>
    //                 }
    //                 <div className="flex-grow" /> {/* Spacer */}
    //                 {getNext(asset) !== undefined
    //                     && <div className="flex flex-col justify-center">
    //                         <button
    //                             className="mr-4 p-1 px-3 pointer-events-auto rounded border border-solid border-white"
    //                             onClick={() => onNext()}
    //                             >
    //                             <i className="fa-solid fa-arrow-right"></i>
    //                         </button>
    //                     </div>
    //                 }
    //             </div>
    //         </div>
            
    //         <div className="photo-header">
    //             <div className="flex flex-row items-center pl-3 pr-3 pt-3 pb-2">
    //                 <button
    //                     className="p-1 px-3 pointer-events-auto rounded border border-solid border-white"
    //                     onClick={() => {
    //                         onClose();
    //                         setOpenInfo(false);
    //                     }}
    //                     >
    //                     <i className="fa-solid fa-close"></i>
    //                 </button>

    //                 <button
    //                     data-testid="open-info-button"
    //                     className="ml-auto p-1 px-3 pointer-events-auto rounded border border-solid border-white"
    //                     onClick={() => {
    //                         setOpenInfo(true);
    //                     }}
    //                     >
    //                     <i className="fa-solid fa-circle-info"></i>
    //                 </button>
    //             </div>
    //         </div>

    //         <Drawer
    //             className="asset-info-drawer"
    //             open={openInfo}
    //             onClose={() => {
    //                 setOpenInfo(false);
    //             }}
    //             size="lg"
    //             anchor="bottom"
    //             >
    //             <AssetInfo
    //                 key={asset._id}
    //                 onClose={() => {
    //                     setOpenInfo(false);
    //                 }}
    //                 onDeleted={() => {
    //                     setOpenInfo(false);
    //                     onClose();
    //                 }}
    //                 />
    //         </Drawer>
    //     </div>
    );
}