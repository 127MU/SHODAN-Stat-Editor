import QtQuick

// Native wheel input and animation; touch dragging remains with the Flickable.
WheelHandler {
    id:wheel
    target:null
    property var view:parent && parent.contentY!==undefined?parent:(parent?parent.parent:null)
    property real destination:0
    property NumberAnimation motion:NumberAnimation {
        target:wheel.view;property:"contentY";duration:160;easing.type:Easing.OutCubic
    }
    onWheel:event=>{
        if(!view || view.contentY===undefined){event.accepted=false;return}
        const lower=view.originY || 0
        const upper=Math.max(lower,lower+view.contentHeight-view.height)
        const pixel=event.pixelDelta.y
        const delta=pixel!==0?-pixel:-event.angleDelta.y/120*Math.max(80,view.height*0.18)
        const start=motion.running?destination:view.contentY
        const next=Math.max(lower,Math.min(upper,start+delta))
        if(next===start){event.accepted=false;return}
        if(typeof view.cancelFlick==="function")view.cancelFlick()
        destination=next
        motion.stop()
        if(pixel!==0)view.contentY=next
        else {motion.from=view.contentY;motion.to=next;motion.start()}
        event.accepted=true
    }
}
