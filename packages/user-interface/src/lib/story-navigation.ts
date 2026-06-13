//
// Computes the index of the next story when navigating backward or forward
// through an ordered story list, wrapping around at either end.
//
// `currentIndex` is the index of the currently selected story, or -1 when
// no story is selected (or the selection is not in the list). With no
// current selection, a forward offset selects the first story and a
// backward offset selects the last.
//
// Returns -1 when the list is empty.
//
export function nextStoryIndex(currentIndex: number, offset: number, storyCount: number): number {
    if (storyCount === 0) {
        return -1;
    }
    if (currentIndex === -1) {
        return offset > 0 ? 0 : storyCount - 1;
    }
    return (currentIndex + offset + storyCount) % storyCount;
}
