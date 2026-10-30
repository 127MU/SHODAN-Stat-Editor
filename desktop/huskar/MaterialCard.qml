import QtQuick
import HuskarUI.Basic

// Keep HusCard's layout and controls; only compose its native material background.
HusCard {
    id:card
    required property var store
    // Native HusCard's outer shadow is clipped by scrolling viewports. Keep
    // feedback inside the card's bounds instead, so no hard shadow edge remains.
    hoverable:false
    showShadow:false
    HoverHandler { id:glassHover;enabled:card.store.cardMotion && card.store.hoverEffects }
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
            active:card.visible && card.store.cardMaterial!=="solid" && !!card.store.cardBackdrop
            sourceComponent:HusLiquidGlass {
                id:glassEffect
                anchors.fill:parent
                sourceItem:card.store.cardBackdrop
                sourceRect:surface.sampleRect
                radiusBg.all:card.radiusBg.all
                refraction:card.store.cardMaterial==="glass"?card.store.glassRefraction*(card.store.materialQuality==="economy"?0.5:1):0
                bevelDepth:card.store.cardMaterial==="glass"?0.18:0.11
                bevelWidth:0.09
                frost:card.store.cardMaterial==="glass"?0.02:Math.min(card.store.materialBlur,card.store.materialQuality==="economy"?1:8)
                specularIntensity:card.store.cardMaterial==="glass"?card.store.glassHighlight:0
                animated:card.visible && card.store.cardMaterial==="glass" && card.store.cardMotion && card.store.materialQuality!=="economy" && !(card.store.materialQuality==="balanced" && card.store.materialScrolling)
                magnify:glassHover.hovered?1.06:1.02
                tiltX:glassHover.hovered?(glassHover.point.position.y/Math.max(1,card.height)-0.5)*14:0
                tiltY:glassHover.hovered?(glassHover.point.position.x/Math.max(1,card.width)-0.5)*14:0
                Behavior on tiltX { enabled:card.store.cardMotion;NumberAnimation { duration:HusTheme.Primary.durationFast;easing.type:Easing.OutCubic } }
                Behavior on tiltY { enabled:card.store.cardMotion;NumberAnimation { duration:HusTheme.Primary.durationFast;easing.type:Easing.OutCubic } }
                Behavior on magnify { enabled:card.store.cardMotion;NumberAnimation { duration:HusTheme.Primary.durationFast;easing.type:Easing.OutCubic } }
            }
        }
        HusFrame {
            anchors.fill:parent
            padding:0
            colorBg:HusThemeFunctions.alpha(card.colorBg,card.store.cardMaterial==="solid"?1:card.store.cardMaterial==="frost"?card.store.frostOpacity:card.store.glassOpacity)
            radiusBg.all:card.radiusBg.all
            borderBg.color:glassHover.hovered?HusThemeFunctions.alpha(HusTheme.Primary.colorPrimary,0.65):card.store.cardMaterial==="glass"?HusThemeFunctions.alpha(HusTheme.Primary.colorTextBase,0.42):card.borderBg.color
            borderBg.width:card.borderBg.width
            Behavior on borderBg.color { enabled:card.store.cardMotion;ColorAnimation { duration:HusTheme.Primary.durationFast } }
        }
    }
}
