-- NgontenYuk.co: dukungan pembayaran rental bertahap
-- Tidak menghapus index/constraint: audit database memastikan batas satu pembayaran
-- per rental memang tidak ada. Aman dijalankan ulang.

BEGIN;

-- Validasi total pembayaran aktif (pending + paid) terhadap harga rental.
-- Baris rental dikunci agar dua transaksi pembayaran bersamaan terserialisasi.
CREATE OR REPLACE FUNCTION public.validate_rental_payment_amount()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
DECLARE
  v_rental_price numeric;
  v_reserved_total numeric;
  v_remaining numeric;
BEGIN
  IF NEW.payment_type <> 'rental' THEN
    RETURN NEW;
  END IF;

  SELECT r.rental_price
    INTO v_rental_price
  FROM public.rentals AS r
  WHERE r.id = NEW.rental_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Rental tidak ditemukan.'
      USING ERRCODE = '23503';
  END IF;

  SELECT COALESCE(SUM(p.amount), 0)
    INTO v_reserved_total
  FROM public.payments AS p
  WHERE p.rental_id = NEW.rental_id
    AND p.payment_type = 'rental'
    AND p.payment_status IN ('pending', 'paid')
    AND p.id IS DISTINCT FROM NEW.id;

  IF NEW.payment_status IN ('pending', 'paid') THEN
    v_reserved_total := v_reserved_total + NEW.amount;
  END IF;

  IF v_reserved_total > v_rental_price THEN
    v_remaining := GREATEST(
      v_rental_price - (
        SELECT COALESCE(SUM(p.amount), 0)
        FROM public.payments AS p
        WHERE p.rental_id = NEW.rental_id
          AND p.payment_type = 'rental'
          AND p.payment_status IN ('pending', 'paid')
          AND p.id IS DISTINCT FROM NEW.id
      ),
      0
    );

    RAISE EXCEPTION
      'Total pembayaran aktif tidak boleh melebihi harga rental. Sisa yang dapat dicatat: %.',
      v_remaining
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$function$;

-- Sertakan payment_status agar perpindahan failed/refunded -> pending/paid
-- juga melewati validasi batas total pembayaran.
DROP TRIGGER IF EXISTS validate_rental_payment_amount_trigger
  ON public.payments;

CREATE TRIGGER validate_rental_payment_amount_trigger
BEFORE INSERT OR UPDATE OF rental_id, amount, payment_type, payment_status
ON public.payments
FOR EACH ROW
EXECUTE FUNCTION public.validate_rental_payment_amount();

-- Index idx_payments_rental yang sudah ada tetap dipakai untuk pencarian rental.
-- Index tambahan tidak diperlukan sebelum ada bukti kebutuhan performa.

COMMIT;
