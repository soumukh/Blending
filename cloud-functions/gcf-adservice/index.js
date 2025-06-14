const adsMap = {
    "clothing": [
        { redirect_url: "/product/66VCHSJNUP", text: "Tank top for sale. 20% off." }
    ],
    "accessories": [
        { redirect_url: "/product/1YMWWN1N4O", text: "Watch for sale. Buy one, get second kit for free" }
    ],
    "footwear": [
        { redirect_url: "/product/L9ECAV7KIM", text: "Loafers for sale. Buy one, get second one for free" }
    ],
    "hair": [
        { redirect_url: "/product/2ZYFJ3GM2N", text: "Hairdryer for sale. 50% off." }
    ],
    "decor": [
        { redirect_url: "/product/0PUK6V6EV0", text: "Candle holder for sale. 30% off." }
    ],
    "kitchen": [
        { redirect_url: "/product/9SIQT8TOJO", text: "Bamboo glass jar for sale. 10% off." },
        { redirect_url: "/product/6E92ZMYYFZ", text: "Mug for sale. Buy two, get third one for free" }
    ]
};

const allAds = Object.values(adsMap).flat();

function getRandomAds(maxAds) {
    const result = [];
    for (let i = 0; i < maxAds && allAds.length > 0; i++) {
        const idx = Math.floor(Math.random() * allAds.length);
        result.push(allAds[idx]);
    }
    return result;
}

exports.getAds = (req, res) => {
    try {
        const contextKeys = req.query.context_keys ? req.query.context_keys.split(',') : [];
        console.log(`Received ad request (context_keys=${contextKeys})`);
        
        let selectedAds = [];
        if (contextKeys.length > 0) {
            for (const key of contextKeys) {
                if (adsMap[key]) {
                    selectedAds = selectedAds.concat(adsMap[key]);
                }
            }
        }

        if (selectedAds.length === 0) {
            selectedAds = getRandomAds(2);
        } else if (selectedAds.length > 2) {
            selectedAds = selectedAds.slice(0, 2); // Cap at MAX_ADS_TO_SERVE
        }

        res.status(200).json({ ads: selectedAds });
    } catch (err) {
        console.error(`Ad fetch failed: ${err}`);
        res.status(500).send(`Ad fetch failed: ${err.message}`);
    }
};