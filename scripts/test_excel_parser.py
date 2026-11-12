import unittest
from import_trip_excel import name_and_parameters,phone,money
class ParserTests(unittest.TestCase):
    def test_varied_numbering_and_parameters(self):
        for value,name in [('33 Медведев Сергей 176-85','Медведев Сергей'),('2-Федоров Евгений-50 размер 76кг,','Федоров Евгений'),('1. Щитова М. 9000 р42','Щитова М')]:
            self.assertEqual(name_and_parameters(value)[0],name)
        name,params=name_and_parameters('Новикова Варя (140 см, 31 кг, 12 лет)')
        self.assertEqual((params['height_cm'],params['weight_kg'],params['age_years']),(140,31,12))
    def test_accidental_dates_are_not_parameters(self):
        _,params=name_and_parameters('Анна Тестовая','2026-06-02T00:00:00')
        self.assertNotIn('age_years',params);self.assertNotIn('height_cm',params)
        self.assertNotIn('2026-06-02',params['notes'])
    def test_telephone_operand_is_not_a_calculated_payment(self):
        self.assertEqual(phone({'formula':'+79270000000'}),'+79270000000')
        self.assertIsNone(money({'formula':"SUM('24-25'!H14:I14)",'value':7000}))
        self.assertEqual(money({'value':'6 500 руб'}),650000)
if __name__=='__main__':unittest.main()
