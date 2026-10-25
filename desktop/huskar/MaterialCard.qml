import QtQuick
import HuskarUI.Basic

// Keep HusCard's layout and controls; only compose its native material background.
HusCard {
    id:card
    required property var store
    HoverHandler { id:glassHover;enabled:card.store.cardMaterial==="glass" }
    bgDelegate:Item {
        id:surface
        property rect sampleRect:{
            // Track ancestor translations, including the Flickable's content item.
            let item=surface;let position=0
            while(item){position+=item.x+item.y;item=item.parent}
            if(!card.store.cardBackdrop)return Qt.rect(0,0,width,height)
            const p=mapToItem(card.store.cardBackdrop,0,0)
            const pad=card.store.cardMaterial==="glass"?0.18+(glassLoader.item?glassLoader.item.refraction:0.095):0.11
            return Qt.rect(p.x-width*pad,p.y-height*pad,width*(1+2*pad),height*(1+2*pad))
        }
        Loader {
            id:glassLoader
            anchors.fill:parent
            active:card.store.cardMaterial!=="solid" && !!card.store.cardBackdrop
            sourceComponent:HusLiquidGlass {
                id:glassEffect
                anchors.fill:parent
                sourceItem:card.store.cardBackdrop
                sourceRect:surface.sampleRect
                radiusBg.all:card.radiusBg.all
                refraction:card.store.cardMaterial==="glass"?0.095:0
                bevelDepth:card.store.cardMaterial==="glass"?0.18:0.11
                bevelWidth:0.09
                frost:card.store.cardMaterial==="glass"?0.02:3
                specularIntensity:card.store.cardMaterial==="glass"?2.1:0
                animated:card.store.cardMaterial==="glass" && card.store.cardMotion
                magnify:glassHover.hovered?1.06:1.02
                tiltX:glassHover.hovered?(glassHover.point.position.y/Math.max(1,card.height)-0.5)*14:0
                tiltY:glassHover.hovered?(glassHover.point.position.x/Math.max(1,card.width)-0.5)*14:0
                Behavior on tiltX { NumberAnimation { duration:180;easing.type:Easing.OutCubic } }
                Behavior on tiltY { NumberAnimation { duration:180;easing.type:Easing.OutCubic } }
                Behavior on magnify { NumberAnimation { duration:180;easing.type:Easing.OutCubic } }
                SequentialAnimation on refraction {
                    running:card.store.cardMaterial==="glass" && card.store.cardMotion && card.visible
                    loops:Animation.Infinite
                    NumberAnimation { from:0.075;to:0.115;duration:1900;easing.type:Easing.InOutSine }
                    NumberAnimation { from:0.115;to:0.075;duration:1900;easing.type:Easing.InOutSine }
                    onRunningChanged:if(!running)glassEffect.refraction=card.store.cardMaterial==="glass"?0.095:0
                }
            }
        }
        HusFrame {
            anchors.fill:parent
            padding:0
            colorBg:HusThemeFunctions.alpha(card.colorBg,card.store.cardMaterial==="solid"?1:card.store.cardMaterial==="frost"?0.48:(HusTheme.isDark?0.24:0.16))
            radiusBg.all:card.radiusBg.all
            borderBg.color:card.store.cardMaterial==="glass"?HusThemeFunctions.alpha(HusTheme.Primary.colorTextBase,0.42):card.borderBg.color
            borderBg.width:card.borderBg.width
        }
    }
}
