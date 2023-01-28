import { createLayout } from "./create-layout";

//
// Responsible for row-based gallery layout.
//
export function GalleryLayout({ items = [], galleryWidth = 600, targetRowHeight = 200, baseUrl = "" }) {

    const rows = createLayout(items, galleryWidth, targetRowHeight);

    return (
        <div
            style={{
                width: `${galleryWidth}px`,
            }}
            >
            {rows.map((row, rowIndex) => {
                return (
                    <div
                        key={rowIndex}
                        style={{
                            display: "flex",
                            flexDirection: "row",
                            height: `${row.height}px`,
                        }}
                        >
                        {row.items.map(item => {
                            return (
                                <img 
                                    key={item.thumb}
                                    src={`${baseUrl}${item.thumb}`}
                                    />
                            );
                        })}
                    </div>
                );
            })}

        </div>
    );
}

