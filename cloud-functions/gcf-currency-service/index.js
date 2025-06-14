// Load currency data (reused from server.js)
function _getCurrencyData(callback) {
    const data = require('./currency_conversion.json');
    callback(data);
  }
  
  // Handle decimal/fractional carrying (reused from server.js)
  function _carry(amount) {
    const fractionSize = Math.pow(10, 9);
    amount.nanos += (amount.units % 1) * fractionSize;
    amount.units = Math.floor(amount.units) + Math.floor(amount.nanos / fractionSize);
    amount.nanos = amount.nanos % fractionSize;
    return amount;
  }
  
  // GCF entry point
  exports.convertCurrency = (req, res) => {
    try {
      // Extract query params (HTTP equivalent of gRPC request)
      const { from_currency_code, from_units, from_nanos, to_code } = req.query;
  
      // Validate inputs
      if (!from_currency_code || !to_code || from_units === undefined) {
        return res.status(400).send('Missing required parameters: from_currency_code, to_code, from_units');
      }
  
      // Parse inputs (nanos is optional, default to 0)
      const units = parseFloat(from_units);
      const nanos = from_nanos ? parseInt(from_nanos, 10) : 0;
      if (isNaN(units) || isNaN(nanos)) {
        return res.status(400).send('Invalid units or nanos: must be numbers');
      }
  
      // Mimic the gRPC request structure
      const request = {
        from: {
          currency_code: from_currency_code,
          units: units,
          nanos: nanos
        },
        to_code: to_code
      };
  
      // Reuse the original convert logic
      _getCurrencyData((data) => {
        // Convert: from_currency --> EUR
        if (!data[request.from.currency_code]) {
          return res.status(400).send(`Unsupported currency code: ${request.from.currency_code}`);
        }
        if (!data[request.to_code]) {
          return res.status(400).send(`Unsupported to_code: ${request.to_code}`);
        }

        const from = request.from;
        const euros = _carry({
          units: from.units / data[from.currency_code],
          nanos: from.nanos / data[from.currency_code]
        });
  
        euros.nanos = Math.round(euros.nanos);
  
        // Convert: EUR --> to_currency
        const result = _carry({
          units: euros.units * data[request.to_code],
          nanos: euros.nanos * data[request.to_code]
        });
  
        result.units = Math.floor(result.units);
        result.nanos = Math.floor(result.nanos);
        result.currency_code = request.to_code;
  
        // Send response in JSON (HTTP equivalent of gRPC callback)
        res.status(200).json(result);
      });
    } catch (err) {
      console.error(`Conversion failed: ${err}`);
      res.status(500).send(`Conversion failed: ${err.message}`);
    }
  };